# Strings

Store, inspect, compare, and build text with the `string` type.

Strings appear throughout ArkTS code: UI labels, log messages, file names, JSON payloads, identifiers, and network responses are all text-heavy. Because of that, string handling is one of the first places where clear typing and explicit conversion matter. ArkTS keeps most string syntax familiar to JavaScript and TypeScript developers, but it encourages a more explicit style when strings interact with numbers, nullable values, or dynamically shaped data.

This chapter covers how to write string literals, combine and compare strings, inspect text with common APIs, and convert between strings and other types in an ArkTS-friendly way.

In type annotations, use `string`. Do not treat `String` as the normal type form for everyday ArkTS code.

## String Literals

The simplest way to create a string is with a string literal. ArkTS supports both single-quoted and double-quoted literals:

```typescript
let title: string = 'ArkTS Language Guide';
let chapter: string = "Basic Syntax";
```

If the initializer makes the type obvious, ArkTS can infer `string`:

```typescript
let platform = 'HarmonyOS';
let language = 'ArkTS';
```

String literals are useful for:

- initial values
- argument values
- fixed return values
- enum-style labels and messages

Choose one quoting style and keep it consistent inside a file unless the content itself makes one form clearer.

### Quotes Inside Strings

Use the opposite quote style, or escape the quote character:

```typescript
let message1: string = "It's ready.";
let message2: string = 'He said: \'Start now.\'';
```

This keeps source text readable without changing the string's actual value.

## Multiline Strings

Use a template literal when text spans several lines:

```typescript
let helpText: string = `ArkTS keeps types explicit,
prefers stable object layouts,
and favors predictable runtime behavior.`;
```

A multiline template literal preserves line breaks written in the source. That makes it useful for:

- formatted output
- embedded examples
- diagnostic text
- structured snippets such as JSON templates

```typescript
let emailBody: string = `Hello,

Your download is ready.
Please open the app to continue.`;

console.info(emailBody);
```

If you want your source to wrap across lines but do not want newline characters in the value, concatenate explicitly:

```typescript
let summary: string =
  'ArkTS keeps syntax close to TypeScript ' +
  'while removing several dynamic language patterns.';
```

## Escaping Special Characters

Escape sequences let you represent characters that would otherwise be hard to write directly:

```typescript
let quote: string = 'He said: \'Learn ArkTS.\'';
let path: string = 'C:\\workspace\\guide';
let lines: string = 'first line\nsecond line';
let columns: string = 'name\tvalue';
```

Common escapes include:

- `\'` and `\"` for quotation marks
- `\\` for a backslash
- `\n` for a line break
- `\t` for a horizontal tab

Use escapes when they make the literal more accurate. Do not overuse them when a template literal or a different quote style would be clearer.

### Hexadecimal and Unicode Escapes

ArkTS string literals also support hexadecimal and Unicode escape forms:

```typescript
let copyright: string = '\xA9';
let latinCapitalAWithRing: string = '\u00C5';
let rareCharacter: string = '\u{2F804}';

console.info(copyright);            // ©
console.info(latinCapitalAWithRing); // Å
console.info(rareCharacter);
```

These forms are useful when:

- a character would be hard to type directly
- source files must stay visually unambiguous
- examples need to show the exact code point being used

## Empty Strings and Mutability

An empty string is still a valid `string` value:

```typescript
let input: string = '';
if (input.length === 0) {
  console.info('Input is empty');
}
```

Strings are immutable values. When a variable seems to "change", it is being assigned a new string value rather than modifying the old one in place:

```typescript
let label: string = 'Ark';
label += 'TS';
console.info(label); // ArkTS
```

This distinction matters when designing APIs. A helper that "updates" a string should usually return a new string:

```typescript
function addPrefix(value: string, prefix: string): string {
  return prefix + value;
}

let result: string = addPrefix('Guide', 'ArkTS ');
console.info(result); // ArkTS Guide
```

## Concatenation and Interpolation

Use `+` when combining a small number of known text fragments:

```typescript
let firstName: string = 'Ada';
let lastName: string = 'Lovelace';
let fullName: string = firstName + ' ' + lastName;
```

Use template literals when the output includes several values or expressions:

```typescript
let topic: string = 'Strings';
let lesson: number = 1;
let summary: string = `${topic} lesson ${lesson}`;
console.info(summary);
```

Interpolation is often clearer than manual concatenation because punctuation and spacing stay close to the final output:

```typescript
let completed: number = 7;
let total: number = 16;
let progressText: string = `Progress: ${completed}/${total}`;
console.info(progressText);
```

### Choosing Between `+` and Template Literals

Use `+` for very short joins:

```typescript
let fileName: string = 'report' + '.txt';
```

Use template literals when:

- numbers or booleans are inserted into text
- several values appear in one sentence
- readability matters more than brevity

```typescript
function describeUser(name: string, age: number, active: boolean): string {
  return `User ${name} is ${age} years old and active=${active}.`;
}
```

If a template literal must contain a backtick or the `${` sequence as plain text, escape it explicitly:

```typescript
let codeSample: string = `Use \`name\` as the field key.`;
let placeholderText: string = `Template syntax starts with \${expression}.`;

console.info(codeSample);
console.info(placeholderText);
```

## Working with Characters and Length

Use `length` to inspect the size of a string:

```typescript
let word: string = 'Harmony';
console.info(word.length); // 7
```

For many practical tasks, character-oriented APIs such as `charAt()` are enough:

```typescript
let text: string = 'ArkTS';
let firstChar: string = text.charAt(0);
let lastChar: string = text.charAt(text.length - 1);

console.info(firstChar); // A
console.info(lastChar);  // S
```

An index-based loop is a clear way to examine a string one position at a time:

```typescript
let keyword: string = 'guide';
for (let i = 0; i < keyword.length; i++) {
  console.info(`${i}: ${keyword.charAt(i)}`);
}
```

This style is especially useful when:

- validating a format character by character
- building a normalized result
- counting separators such as `-`, `_`, or `.`

For most application code, `length` and `charAt()` are practical and readable. Keep in mind that they operate on UTF-16 code units, so some Unicode characters may take more than one position:

```typescript
let symbol: string = '🙂';
console.info(symbol.length); // 2
console.info(symbol.charAt(0));
```

That detail matters mainly when you validate or slice user-facing text containing emoji or less common Unicode characters.

## Common String Operations

ArkTS inherits a broad set of practical string methods. A few appear in everyday code constantly:

```typescript
let source: string = '  ArkTS Guide  ';

console.info(source.trim());             // ArkTS Guide
console.info(source.toUpperCase());      //   ARKTS GUIDE
console.info(source.toLowerCase());      //   arkts guide
console.info(source.includes('Guide'));  // true
console.info(source.startsWith('  Ark')); // true
console.info(source.endsWith('  '));     // true
```

Use substring-style methods to extract part of a string:

```typescript
let version: string = 'v2.3.1';
let majorPart: string = version.substring(1, 2);
console.info(majorPart); // 2
```

Use replacement APIs to normalize small text fragments:

```typescript
let fileLabel: string = 'arkts-guide-draft';
let finalLabel: string = fileLabel.replace('draft', 'final');
console.info(finalLabel); // arkts-guide-final
```

### Searching Within Text

Use these methods depending on the question you are asking:

- `includes()` to test whether text appears at all
- `startsWith()` to test a prefix
- `endsWith()` to test a suffix
- `indexOf()` when the position matters

```typescript
let route: string = '/docs/strings';

if (route.startsWith('/docs/')) {
  console.info('Documentation route');
}

let slashIndex: number = route.indexOf('/', 1);
console.info(slashIndex);
```

## Comparing Strings

Compare strings with strict equality when you want exact matches:

```typescript
let expected: string = 'ok';
let actual: string = 'ok';

if (expected === actual) {
  console.info('Matched');
}
```

Lexicographic ordering is also available:

```typescript
let a: string = 'apple';
let b: string = 'banana';

console.info(a < b); // true
```

When comparison should ignore casing or surrounding whitespace, normalize first:

```typescript
function sameCommand(left: string, right: string): boolean {
  return left.trim().toLowerCase() === right.trim().toLowerCase();
}

console.info(sameCommand(' Start ', 'start')); // true
```

This is usually better than scattering partial cleanup logic around multiple call sites.

## Strings and Other Types

Strings often interact with numbers, booleans, and nullable values. In ArkTS, the clearest approach is to convert values explicitly instead of relying on loose JavaScript coercion.

Template literals make mixed-type output straightforward:

```typescript
let retries: number = 3;
let enabled: boolean = true;
let textValue: string = `Retries=${retries}, enabled=${enabled}`;
console.info(textValue);
```

To turn a number into text, call `toString()`:

```typescript
let count: number = 42;
let countText: string = count.toString();
console.info(countText); // 42
```

### Nullable Text

Many APIs return `string | null`. Handle that state explicitly:

```typescript
function displayName(name: string | null): string {
  if (name === null || name.trim().length === 0) {
    return 'Anonymous';
  }
  return name;
}
```

This style is clearer than depending on broad truthy or falsy checks when the domain is specifically "text or missing text".

## Parsing Text into Numbers

Text from input fields, files, and network payloads often needs to become numeric data. Prefer explicit parsing APIs:

```typescript
let integerText: string = '42';
let floatText: string = '3.14';

let integerValue: number = Number.parseInt(integerText, 10);
let floatValue: number = Number.parseFloat(floatText);

console.info(integerValue); // 42
console.info(floatValue);   // 3.14
```

When parsing user input, validate the result before using it:

```typescript
function parsePort(text: string): number {
  let port: number = Number.parseInt(text, 10);
  if (Number.isNaN(port) || port <= 0) {
    throw new Error(`Invalid port: ${text}`);
  }
  return port;
}
```

This keeps parsing and validation close together and avoids passing invalid numbers deeper into the program.

### Prefer Explicit Conversion Over Implicit Coercion

JavaScript often relies on implicit numeric conversion:

```typescript
let rawCount: string = '5';
// let count = +rawCount; // Do not use in ArkTS examples
```

In ArkTS, prefer the explicit version:

```typescript
let rawCount: string = '5';
let count: number = Number.parseInt(rawCount, 10);
console.info(count + 1); // 6
```

This is more readable and matches ArkTS operator restrictions.

## Building Strings in Loops

For small outputs, repeated concatenation is acceptable:

```typescript
let result: string = '';
for (let i = 1; i <= 3; i++) {
  result += `item${i} `;
}
console.info(result.trim()); // item1 item2 item3
```

When assembling text from a collection, building an array and joining it is often easier to read:

```typescript
let parts: string[] = [];
parts.push('ArkTS');
parts.push('keeps');
parts.push('types');
parts.push('explicit');

let sentence: string = parts.join(' ');
console.info(sentence); // ArkTS keeps types explicit
```

This pattern works well when:

- some parts are conditional
- values come from loops
- separators should be handled in one place

```typescript
function joinTags(tags: string[]): string {
  let visibleTags: string[] = [];
  for (let tag of tags) {
    if (tag.trim().length > 0) {
      visibleTags.push(tag.trim());
    }
  }
  return visibleTags.join(', ');
}
```

## Practical Patterns

### Formatting a Status Line

```typescript
function formatStatus(user: string, completed: number, total: number): string {
  return `${user}: ${completed}/${total} completed`;
}

console.info(formatStatus('Ada', 3, 5));
```

### Normalizing User Input

```typescript
function normalizeKeyword(value: string): string {
  return value.trim().toLowerCase();
}

console.info(normalizeKeyword('  ArkTS  ')); // arkts
```

### Parsing Delimited Text

```typescript
function parseCsvLine(line: string): string[] {
  let rawItems: string[] = line.split(',');
  let result: string[] = [];

  for (let item of rawItems) {
    result.push(item.trim());
  }

  return result;
}

let columns: string[] = parseCsvLine('name, age, city');
console.info(columns.join(' | ')); // name | age | city
```

## ArkTS Restrictions That Affect Strings

Most string syntax looks familiar, but several JavaScript and TypeScript habits should not appear in ArkTS guide examples:

- Do not rely on unary `+` to convert a string to a number.
- Do not use `any` or `unknown` to bypass text validation.
- Do not use dynamic property access patterns as a substitute for proper string processing.
- Do not introduce TypeScript-only string literal types, template literal types, or `as const` guidance in ArkTS string examples.
- Prefer explicit parsing and explicit return values in helper functions.

The following JavaScript-style code is not an ArkTS-friendly pattern:

```typescript
// let size = +'12'; // Avoid
```

Use an explicit conversion instead:

```typescript
let sizeText: string = '12';
let size: number = Number.parseInt(sizeText, 10);
console.info(size);
```

Likewise, avoid loosely typed APIs:

```typescript
function formatCount(count: number): string {
  return `Count: ${count}`;
}
```

This is better than taking an `any` value and hoping it can be rendered correctly.

Strings also interact closely with other chapters:

- for loop-based text processing, see `control-flow.md`
- for arrays or maps of text values, see `collection-types.md`
- for reusable text-building helpers, see `functions.md`
