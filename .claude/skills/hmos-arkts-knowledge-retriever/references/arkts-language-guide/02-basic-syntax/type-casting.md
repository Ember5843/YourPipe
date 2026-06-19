# Type Casting

Narrow values, assert a more specific type, or convert data explicitly when the program requires it.

Type casting in ArkTS should be used carefully. The goal is not to bypass the type system, but to express knowledge that the program genuinely has about a value. ArkTS keeps casting syntax and narrowing rules narrower than TypeScript, which encourages explicit checks and clear data flow.

In practice, three related but different operations appear in this area:

- type assertion with `as T`
- control-flow-based narrowing with checks such as `instanceof`, `typeof`, and `null` comparisons
- explicit value conversion such as turning a string into a number

Keeping these cases separate makes ArkTS code easier to reason about.

## Using `as`

ArkTS supports `as T` as the casting syntax:

```typescript
class BaseShape {}

class RoundShape extends BaseShape {
  radius: number = 10;
}

function createShape(): BaseShape {
  return new RoundShape();
}

let shape: BaseShape = createShape();
let circle: RoundShape = shape as RoundShape;
console.info(circle.radius);
```

Use `as` only when you know the runtime value is compatible with the target type.

Good uses of `as` include:

- narrowing after a trustworthy runtime check
- refining a broad declared type to the specific type a branch has established
- expressing information that is already guaranteed by the surrounding logic

### `as` Is Not Just a TypeScript-Style Hint

In TypeScript, a type assertion is erased and has no runtime effect. In ArkTS, a wrong cast is stricter: it can fail at compile time or raise a runtime `ClassCastException`.

That means `as` should be treated as a real claim about the runtime value, not as a convenient way to silence the type checker.

### Use `as T` Only

ArkTS does not support TypeScript's angle-bracket assertion syntax:

```typescript
// Avoid TypeScript-style assertions such as:
// let circle = <Circle>shape;
```

Keep cast syntax simple and explicit with `as T`.

## Casting Is Not a Substitute for Good Types

If many casts are needed, the underlying types are often too vague:

```typescript
class Message {
  text: string;

  constructor(text: string) {
    this.text = text;
  }
}
```

It is usually better to improve the API, class hierarchy, or interface design than to keep adding `as` everywhere.

Prefer:

- explicit interfaces
- clear class hierarchies
- nullable checks
- `instanceof` for reference types

Overuse of `as` usually signals that the code should be redesigned.

## Do Not Rely on `any` or `unknown`

TypeScript code often uses `any` or `unknown` as a staging point before asserting a final type. ArkTS does not support either type.

```typescript
// Avoid TypeScript-style patterns such as:
// let result = expr as any as Target;
// let value = expr as unknown as Target;
```

Instead, keep the declared type explicit from the start, or narrow through normal control flow before using `as`.

## Narrowing with `instanceof`

`instanceof` checks whether a reference value is an instance of a class:

```typescript
class Animal {}

class Cat extends Animal {
  meow(): void {
    console.info('meow');
  }
}

function speak(animal: Animal): void {
  if (animal instanceof Cat) {
    animal.meow();
  }
}
```

Inside the guarded branch, ArkTS narrows the type to `Cat`.

This pattern is especially useful when a parameter or field can hold one of several class types.

### `instanceof` Works with Reference Types

ArkTS supports `instanceof` only when the left operand is an object instance or another reference value. It is not a general-purpose test for primitive values.

```typescript
// Avoid primitive checks such as:
// let count: number = 42;
// let ok = count instanceof Number;
```

Use `instanceof` for class instances, arrays, or other reference values. Use `typeof` or explicit comparisons for primitive cases.

### Primitive Wrappers Need Explicit Construction

If code genuinely needs a boxed primitive object, create that object explicitly:

```typescript
let wrapped = new Number(5.0);
console.info(wrapped instanceof Number); // true
```

Do not treat `5 as Number` as a normal way to create a boxed value. In ArkTS, object construction and type assertion are different operations.

## Narrowing in Control Flow

Type checks often appear inside ordinary conditional logic:

```typescript
class TextMessageContent {
  text: string;

  constructor(text: string) {
    this.text = text;
  }
}

class VisualAssetContent {
  url: string;

  constructor(url: string) {
    this.url = url;
  }
}

function describeContent(content: TextMessageContent | VisualAssetContent): string {
  if (content instanceof TextMessageContent) {
    return content.text;
  }
  return content.url;
}
```

This keeps branches explicit and easy to follow.

Another example:

```typescript
class FileResult {
  path: string;

  constructor(path: string) {
    this.path = path;
  }
}

class ErrorResult {
  message: string;

  constructor(message: string) {
    this.message = message;
  }
}

function showResult(result: FileResult | ErrorResult): string {
  if (result instanceof FileResult) {
    return `File: ${result.path}`;
  }
  return `Error: ${result.message}`;
}
```

## Nullable Values

Another common narrowing pattern is checking for `null`:

```typescript
function printName(name: string | null): void {
  if (name !== null) {
    console.info(name.toUpperCase());
  }
}
```

This is often enough for optional state held in properties or function results.

A nullable check also works well with early returns:

```typescript
function titleLength(title: string | null): number {
  if (title === null) {
    return 0;
  }
  return title.length;
}
```

This keeps the non-null branch simple and lets later code treat the value as the narrower type.

## Equality-Based Narrowing

A value can also be narrowed by comparing it to known values:

```typescript
function describeState(state: 'ready' | 'running' | 'done'): string {
  if (state === 'ready') {
    return 'Ready to start';
  }
  if (state === 'running') {
    return 'Currently running';
  }
  return 'Completed';
}
```

Even without explicit class casts, control flow can still narrow the valid possibilities for a value.

This style is often clearer than broad truthy or falsy checks because it names the exact case being handled.

## `typeof` in Expressions

ArkTS allows `typeof` in expression contexts:

```typescript
let count: number = 3;
console.info(typeof count); // number
```

This can be useful for diagnostics, logging, and simple runtime inspection.

You can also use it to distinguish between primitive cases in ordinary control flow:

```typescript
function normalize(value: string | number): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  return value.toString();
}
```

This is especially useful when a union contains primitive types rather than class instances.

### Remember That `typeof null` Is `"object"`

This behavior comes from JavaScript itself, so `typeof` alone is not enough to distinguish objects from `null`.

```typescript
function printAll(values: string[] | string | null): void {
  if (values !== null && typeof values === 'object') {
    for (let i = 0; i < values.length; i++) {
      console.info(values[i]);
    }
    return;
  }

  if (typeof values === 'string') {
    console.info(values);
  }
}
```

When `null` is possible, exclude it explicitly before treating a value as an object-like branch.

### Do Not Use `typeof` in Type Positions

ArkTS supports `typeof` for runtime expressions, not for TypeScript-style type queries.

```typescript
// Avoid TypeScript-style declarations such as:
// let other: typeof count;
```

Write the actual type explicitly instead.

## Explicit Value Conversion

Do not mix up type assertions with value conversion. A type assertion changes how code treats a value; a conversion produces a different value in the desired form.

For example, when a numeric string must become a number, use explicit conversion logic:

```typescript
function parsePort(text: string): number {
  let parsed = Number.parseInt(text, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Invalid port: ${text}`);
  }
  return parsed;
}
```

This is clearer than relying on JavaScript-style implicit coercion.

### Do Not Rely on Unary Numeric Coercion

JavaScript often converts strings to numbers with unary operators such as `+'5'`. ArkTS does not support that style for strings.

```typescript
// Avoid JavaScript-style coercions such as:
// let port = +'8080';
```

If conversion is required, perform it explicitly.

## Type Guarding Without `is`

TypeScript supports user-defined type predicates such as `arg is Foo`. ArkTS does not support that syntax.

Use a boolean-returning helper together with `instanceof`, then cast locally in the guarded branch if needed:

```typescript
class Foo {
  foo: string = '';
}

function isFoo(value: Object): boolean {
  return value instanceof Foo;
}

function printFoo(value: Object): void {
  if (isFoo(value)) {
    let fooValue = value as Foo;
    console.info(fooValue.foo);
  }
}
```

This keeps the narrowing logic explicit and stays within ArkTS's supported feature set.

## Safe Narrowing Patterns

The safest narrowing patterns in ArkTS are:

- `instanceof` for class-based reference types
- explicit `null` checks
- equality checks for literal cases
- `typeof` in expression contexts
- small, local `as` casts backed by real program logic

For example:

```typescript
function printValue(value: string | number | null): void {
  if (value === null) {
    console.info('No value');
    return;
  }

  if (typeof value === 'string') {
    console.info(value.toUpperCase());
    return;
  }

  console.info(value.toFixed(2));
}
```

This style is explicit, local, and easy to verify.

## Avoiding Unsafe Casts

Casting should not become a shortcut around good type design. If many casts are needed, the API is often too broad or the data model is unclear.

Unsafe style:

```typescript
class MessageText {
  text: string = '';
}

function printLength(value: Object): void {
  let message = value as MessageText;
  console.info(message.text.length);
}
```

Safer style:

```typescript
function printText(value: string | null): void {
  if (value === null) {
    return;
  }
  console.info(value.length);
}
```

The safer version avoids a cast entirely by modeling the real states up front.

## ArkTS Restrictions That Affect Casting

ArkTS narrows the TypeScript casting story in several important ways:

- only `as T` is supported for cast syntax
- incorrect casts may fail at compile time or throw `ClassCastException`
- `any` and `unknown` are not supported
- `instanceof` works with reference types, not primitive values
- `typeof` is allowed only in expression contexts, not in type positions
- the `is` operator is not supported; use `instanceof` and local `as` instead
- the `in` operator is not supported as a narrowing tool

### Do Not Rely on `in`

JavaScript commonly uses the `in` operator to test whether an object has a property. ArkTS does not support this operator.

Rewrite these cases with:

- `instanceof`
- explicit class or interface design
- `null` checks
- direct access to declared members

Keep casts and narrowing small, local, and justified by the program's actual control flow.

For control-flow-based narrowing, see `control-flow.md`. For class hierarchies used with `instanceof`, see `inheritance.md`.
