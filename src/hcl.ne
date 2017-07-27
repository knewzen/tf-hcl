@preprocessor typescript

@{%
/* tslint:disable:curly */
import HclLexer, {Token} from './lexer';
import {Node, Location, Position, Parent, Text} from './types';

const lexer = new HclLexer();

function nil(): null { return null; }

function hasValue(x: any): boolean {
  return x && (typeof x.value === 'string');
}

function asString(d: (Token | Node)[]): string {
  return d.filter(hasValue)
    .map((el: Token | Text) => el.value)
    .join('');
}

function nth(i: number) {
  return (data: any[]): any => data[i];
}

function flatten(d: any[][]): any[] {
  return d.reduce((a, b) => a.concat(b), []);
}

type NodeCreator = (...args: any[]) => Node;

function asNode(type: string, func: (...args: any[]) => any): NodeCreator {
  return (data, offset, reject) => {
    const node = func(data, offset, reject);
    return { type, ...node };
  };
}

function mergeValue([t]: Token[] | Text[]): any {
  return {value: t.value};
}

function locationFromToken(token: Token): Location {
    const {line, col: column, lineBreaks, size, value, offset} = token;
    if (lineBreaks === 0) {
      return {
        start: {line, column, offset},
        end: {
          line,
          column: column + size,
          offset: offset + size,
        },
      };
    } else {
      return {
        start: {line, column, offset},
        end: {
          line: line + lineBreaks,
          column: value.length - value.lastIndexOf('\n'),
          offset: offset + size,
        },
      };
    }
}

function locationFromTokens(first: Token, last: Token): Location {
  const start = locationFromToken(first).start;
  const end = locationFromToken(last).end;
  return {start, end};
}

function asTokenNode(type: string = '$token', func: (...args: any[]) => object = mergeValue): (...args: any[]) => Node {
  return asNode(type, (data, offset, reject) => {
    const [token] = data;
    return {
      ...func(data, offset, reject),
      position: locationFromToken(token),
    };
  });
}

const textNode = asNode('Text', ([d]: Node[][]) => {
  const value = asString(d);
  const [first] = d;
  if (d.length === 1) {
    return { value, position: first.position };
  }
  const last = d[d.length - 1];
  return {
    value: asString(d),
    position: {
      start: first.position.start,
      end: last.position.end,
    },
  };
});

%}

@lexer lexer

# --------------------------------------------

# ## Main config body

# A config is a series of declarations.
Config -> _ Declarations:? _ {% asNode('Config', ([, children]) => ({ children })) %}

Declarations ->
  Declaration (_ Declaration {% nth(1) %} ):*
  {%
    ([first, rest]) => rest ? [first].concat(rest) : [first]
  %}

# A declaration can be either a member declaration or an assignment.
Declaration -> MemberDeclaration {% id %} | Assignment {% id %}

# A member declaration does not use the equals sign.
# @example
#     resource "aws_instance" "foo" {}
MemberDeclaration ->
  Key ws (Section {% nth(0) %} | Declaration {% id %})
  {%
    asNode('MemberDeclaration', ([left, , right]) => ({
      children: [left, right],
      position: {
        start: left.position.start,
        end: right.position.end,
      },
    }))
  %}

# An assignment uses the equals sign to set a value.
# @example
#     instance_count = 42
Assignment ->
  Key _ Equals _ Expression
  {%
    asNode('Assignment', ([left, , , , right]) => ({
      children: [left, right],
      position: {
        start: left.position.start,
        end: right.position.end,
      },
    }))
  %}

Expression -> Section {% id %} | Primitive {% id %}

Section ->
  %openBrace _ (Declarations _ {% nth(0) %} ):? %closeBrace
  {%
    asNode('Section', ([openBrace,,children, closeBrace]) => ({
      children,
      position: locationFromTokens(openBrace, closeBrace),
    }))
  %}

Key -> Identifier {% asNode('Key', ([d]) => ({ name: d.value, children: [d], position: d.position })) %}
  | StringLiteral {% asNode('Key', ([d]) => ({ name: d, children: [d], position: d.position })) %}

Identifier -> %identifier {% asTokenNode('Identifier', ([d]: Token[]) => ({value: d.value})) %}

# -------------------------------------------

# ## Literals
Primitive -> Boolean {% id %} | Number {% id %} | String {% id %}

Boolean -> %boolean {% asTokenNode('Boolean') %}

Number -> %baseTenNumber {% asTokenNode('Number') %}

String -> StringLiteral {% id %} | TemplateString {% id %} | Heredoc {% id %} | IndentedHeredoc {% id %}

StringLiteral ->
  %beginString StringContent:? %endString
  {%
    asNode('StringLiteral', ([start, value, end]) => ({
      value: value.value,
      position: locationFromTokens(start, end),
    }))
  %}

StringContent -> StringChar:+ {% textNode %}

HeredocContent -> (%heredocChar {% asTokenNode() %} | %newline {% asTokenNode() %} ):+ {% textNode %}

StringChar
  -> %stringChar {% asTokenNode() %}
  | %newline {% asTokenNode() %}
  | %escapedDollar {% asTokenNode() %}

TemplateString ->
  %beginString (
    StringContent:? Interpolation
    {%
      ([str, interp]) => {
        if (str) {
          return [str, interp];
        }
        return [interp];
      }
    %}
  ):+ StringContent:? %endString
  {%
    asNode('TemplateString', ([beginString, startContents, endContents, endString]) => ({
      children: flatten(startContents).concat(endContents ? [endContents] : []),
      position: locationFromTokens(beginString, endString),
    }))
  %}

Heredoc ->
  %beginHeredoc HeredocContent:? (
    Interpolation HeredocContent:? {% ([interp, content]) => content ? [interp, content] : [interp] %}
  ):* %endHeredoc
  {%
    asNode('Heredoc', ([beginString, first, rest, endString]) => ({
      indented: false,
      tag: beginString.tag,
      children: (first ? [first] : []).concat(flatten(rest)),
      position: locationFromTokens(beginString, endString),
    }))
  %}


IndentedHeredoc ->
  %beginIndentedHeredoc HeredocContent:? (
    Interpolation HeredocContent:? {% ([interp, content]) => content ? [interp, content] : [interp] %}
  ):* %endHeredoc
  {%
    asNode('IndentedHeredoc', ([beginString, first, rest, endString]) => ({
      indented: true,
      tag: beginString.tag,
      children: [first].concat(flatten(rest)),
      position: locationFromTokens(beginString, endString),
    }))
  %}

Interpolation ->
  %beginInterpolation _ InterpolatedExpression _ %endInterpolation
  {%
    asNode('Interpolation', ([beginInterp, , expression, , endInterp]) => ({
      children: [expression],
      position: locationFromTokens(beginInterp, endInterp),
    }))
  %}

InterpolatedExpression
  -> FunctionCall {% id %}
  | Primitive {% id %}

FunctionCall ->
  Identifier %openParen _ InterpolatedExpression _ %closeParen
  {%
    asNode('FunctionCall', ([funcName,,,arg,,closeParen]) => ({
      name: funcName.value,
      children: [arg],
      position: {
        start: funcName.position.start,
        end: locationFromToken(closeParen).end,
      },
    }))
  %}

# ## Tokens
Equals -> %equal

# ## Whitespace and comments
_ -> ws:? {% nil %}
ws -> (%ws | LineComment | BlockComment) {% nil %}

LineComment -> %beginLineComment %commentText:* %endComment

BlockComment -> %beginBlockComment (%commentText | BlockComment):* %endBlockComment
