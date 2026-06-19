# Functions

Define reusable units of behavior with typed parameters and typed return values.

Functions package behavior into named operations. They can transform input into output, validate values, print messages, build collections, or coordinate larger pieces of work. In ArkTS, functions remain close to the TypeScript model, but they are used in a more explicit and statically typed style.

That means function signatures should make intent clear: parameter types should be specific, return values should be predictable, and examples should avoid dynamic callable-object patterns that depend on JavaScript flexibility. This chapter covers how to define functions, pass them around as values, and write function-oriented APIs that fit ArkTS well.

## Defining and Calling Functions

Use the `function` keyword to declare a function:

```typescript
function greet(name: string): string {
  return `Hello, ${name}`;
}

let message: string = greet('ArkTS');
console.info(message);
```

A function declaration includes:

- the function name
- zero or more parameters
- an optional explicit return type
- a function body

The function name should describe what the function does, not how it does it. `parsePort`, `formatUser`, and `isReady` communicate intent more clearly than `handleData`.

## Parameters

Functions can take one parameter or many parameters:

```typescript
function add(x: number, y: number): number {
  return x + y;
}

function formatUser(name: string, age: number): string {
  return `${name} (${age})`;
}
```

Arguments are passed in the declared order, so parameter order should match how callers naturally think about the operation.

### Functions Without Parameters

Some functions do not require input:

```typescript
function currentTopic(): string {
  return 'Functions';
}
```

Even without parameters, a function is still useful when it names a specific piece of behavior or encapsulates a computed result.

### Default Parameter Values

Default values simplify calls when one argument usually has the same value:

```typescript
function repeat(text: string, times: number = 2): string {
  let result: string = '';
  for (let i = 0; i < times; i++) {
    result += text;
  }
  return result;
}

console.info(repeat('Hi'));    // HiHi
console.info(repeat('Hi', 3)); // HiHiHi
```

Default parameters are often better than creating several tiny wrapper functions. They keep one API centered around one concept.

### Optional Parameters

Use `?` when a parameter may be omitted:

```typescript
function greetUser(name: string, title?: string): string {
  if (title === undefined) {
    return `Hello, ${name}`;
  }
  return `Hello, ${title} ${name}`;
}

console.info(greetUser('Ada'));
console.info(greetUser('Ada', 'Dr.'));
```

Inside the function body, an optional parameter must be treated as a value that may be `undefined`.

Optional parameters and default parameters solve related but different problems:

- use `title?: string` when the argument is genuinely optional
- use `title: string = 'Guest'` when the function should always continue with a known fallback value

### Optional-Style Parameters with Union Types

When a parameter may be omitted by passing `null` or another explicit value, handle that case directly:

```typescript
function describeUser(name: string, title: string | null): string {
  if (title === null) {
    return name;
  }
  return `${name} (${title})`;
}
```

This makes the possible states visible in the type instead of leaving them implicit.

### Passing Objects and Arrays

Arguments are passed by value, but object and array values still refer to shared data. That means reassigning a parameter only changes the local parameter, while updating a declared property or array element changes the original value:

```typescript
class CounterState {
  count: number;

  constructor(count: number) {
    this.count = count;
  }
}

function incrementState(state: CounterState): void {
  state.count += 1;
}

function replaceFirst(values: number[]): void {
  values[0] = 99;
}

let state: CounterState = new CounterState(0);
let values: number[] = [1, 2, 3];

incrementState(state);
replaceFirst(values);

console.info(state.count); // 1
console.info(values[0]);   // 99
```

In ArkTS, updates like these must still follow the declared type. Functions should modify only fields and elements that are already part of the value's explicit structure.

### Parameter Design Guidelines

Good parameter lists are:

- short enough to understand quickly
- specific about accepted types
- ordered by how callers think about the operation
- stable across call sites

If a function starts collecting too many unrelated parameters, that often signals a missing class or interface.

## Return Values

Many functions compute and return a result:

```typescript
function square(value: number): number {
  return value * value;
}
```

Some functions perform side effects and return `void`:

```typescript
function logStatus(status: string): void {
  console.info(status);
}
```

Use the return type to communicate what callers can expect. A function that may fail to produce a result should say so explicitly:

```typescript
function firstElement(values: string[]): string | undefined {
  return values[0];
}
```

### Prefer Explicit Return Types

ArkTS supports return type inference in many situations, but explicit return types are often clearer, especially in public APIs, recursive functions, and more complex logic:

```typescript
function grade(score: number): string {
  if (score >= 90) {
    return 'A';
  }
  if (score >= 80) {
    return 'B';
  }
  return 'C';
}
```

Explicit return types help in three ways:

- they document the function's contract
- they prevent accidental return-type changes during edits
- they avoid ArkTS inference limits in some scenarios

### Returning Early

Functions do not need to build a result in one place. Early returns often make the logic clearer:

```typescript
function parseEnabledFlag(value: string): boolean {
  if (value === 'true') {
    return true;
  }
  if (value === 'false') {
    return false;
  }
  throw new Error(`Invalid flag: ${value}`);
}
```

This style keeps each case short and easy to follow.

## Function Types

Functions are values, so they can be stored in variables, passed to other functions, and returned from functions. A function type describes what arguments such a value accepts and what it returns:

```typescript
function multiply(a: number, b: number): number {
  return a * b;
}

let operation: (a: number, b: number) => number = multiply;
console.info(operation(3, 4)); // 12
```

Function type syntax is useful for:

- variables that store callbacks
- parameters that accept functions
- properties that store callable values

You can also introduce a type alias when the same function shape appears in several places:

```typescript
type NumberTransform = (value: number) => number;

let double: NumberTransform = (value: number): number => {
  return value * 2;
};
```

This often makes APIs easier to read.

## Functions as Parameters

Pass a function to another function when one operation needs a reusable strategy:

```typescript
function applyToEach(values: number[], transform: (value: number) => number): number[] {
  let result: number[] = [];
  for (let value of values) {
    result.push(transform(value));
  }
  return result;
}

let doubled: number[] = applyToEach([1, 2, 3], (value: number): number => {
  return value * 2;
});
```

This pattern is common in:

- collection processing
- validation pipelines
- formatting helpers
- asynchronous code

When a callback shape appears repeatedly, give it a name:

```typescript
type StringPredicate = (value: string) => boolean;

function countMatches(values: string[], predicate: StringPredicate): number {
  let count: number = 0;
  for (let value of values) {
    if (predicate(value)) {
      count++;
    }
  }
  return count;
}
```

### Designing Callback Parameters

Callback types should describe how the callback is actually invoked. If your function always passes an index, write the index as a required parameter:

```typescript
type IndexedLogger = (value: string, index: number) => void;

function logEach(values: string[], callback: IndexedLogger): void {
  for (let i = 0; i < values.length; i++) {
    callback(values[i], i);
  }
}
```

Do not mark a callback parameter as optional unless the caller really may receive fewer arguments in some calls. Otherwise the function type suggests behavior that never happens and makes callback code harder to reason about.

## Arrow Functions

Arrow functions are a concise way to write small function values:

```typescript
let squareValue: (value: number) => number = (value: number): number => {
  return value * value;
};
```

They are especially useful for callbacks:

```typescript
let names: string[] = ['Ada', 'Grace', 'Linus'];
let uppercased: string[] = names.map((name: string): string => {
  return name.toUpperCase();
});
```

In ArkTS, arrow functions are also the preferred replacement for nested function declarations and function expressions.

### Using Arrow Functions for Local Helpers

When a function needs a small helper, store an arrow function in a local variable:

```typescript
function printTotal(a: number, b: number): void {
  let printLine: (text: string) => void = (text: string): void => {
    console.info(text);
  };

  let total: number = a + b;
  printLine(`Total: ${total}`);
}
```

This keeps the code compatible with ArkTS restrictions while still allowing local structure.

### Closures with Arrow Functions

Even though ArkTS does not support nested function declarations, local arrow functions can still capture values from the surrounding scope:

```typescript
function createFormatter(prefix: string): (value: string) => string {
  let format: (value: string) => string = (value: string): string => {
    return `${prefix}: ${value}`;
  };

  return format;
}

let errorFormatter: (value: string) => string = createFormatter('Error');
console.info(errorFormatter('Disk is full'));
```

This is a closure: the returned arrow function continues to use `prefix` from the outer function after the outer function has finished. Use this pattern when it makes an API simpler, but keep the captured state easy to understand.

## Rest Parameters

Use a rest parameter when a function accepts a variable number of arguments of the same type:

```typescript
function sum(...values: number[]): number {
  let total: number = 0;
  for (let i = 0; i < values.length; i++) {
    total += values[i];
  }
  return total;
}

console.info(sum(1, 2, 3, 4));
```

This is clearer than working with loose JavaScript-style argument objects.

Rest parameters are a good fit when:

- all extra arguments have the same type
- the function conceptually processes a list
- callers benefit from direct argument syntax

Rest parameters are the ArkTS-friendly way to model variable-length argument lists. Prefer them over JavaScript-style `arguments` patterns.

## Overload-Style API Design

TypeScript supports overloads, but in ArkTS documentation it is usually clearer to prefer explicit parameter types, unions, optional parameters, default parameters, or a small number of separate functions unless overloads provide clear value.

A simple union-based API is often enough:

```typescript
function normalize(value: string | number): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  return value.toString();
}
```

Use this style only when the accepted cases are small and well defined. If behavior differs substantially between cases, separate functions may be easier to understand.

This keeps function APIs explicit without leaning on more complex TypeScript-only patterns.

## Local Helper Logic

Some functions need internal structure but should still expose one clear public operation. In ArkTS, use variables plus arrow functions instead of nested function declarations:

```typescript
function formatRange(start: number, end: number): string {
  let formatPart: (value: number) => string = (value: number): string => {
    return `[${value}]`;
  };

  return `${formatPart(start)} -> ${formatPart(end)}`;
}
```

This preserves local clarity without relying on unsupported nested functions.

## Recursive Functions

Recursion is supported when the stopping condition and return type are clear:

```typescript
function factorial(value: number): number {
  if (value <= 1) {
    return 1;
  }
  return value * factorial(value - 1);
}
```

Recursive functions should use explicit return types in ArkTS examples. That keeps the intent readable and avoids inference issues.

This guidance matters even more when functions call each other. ArkTS restricts some return-type inference cases, so public APIs and mutually dependent functions should state return types explicitly.

Another example is traversing nested data:

```typescript
function countDown(value: number): void {
  console.info(value);
  if (value <= 0) {
    return;
  }
  countDown(value - 1);
}
```

Recursion is useful when the data or logic is naturally recursive, but keep the base case obvious.

## Generic Functions

Generics make a function reusable across several types while preserving type relationships:

```typescript
function firstElement<T>(items: T[]): T | undefined {
  return items[0];
}

let firstName: string | undefined = firstElement<string>(['A', 'B']);
let firstNumber: number | undefined = firstElement<number>([1, 2]);
```

Often the type argument can be inferred:

```typescript
let nameResult: string | undefined = firstElement(['Ada', 'Grace']);
```

Type inference for generic function calls is strongest when the type information comes from the arguments. If the type can only be inferred from the return value, specify the type argument explicitly.

Generic functions are especially useful when:

- input and output types are connected
- a helper works across multiple element types
- you want reuse without losing type information

### Generic Callbacks

```typescript
function mapValues<T, R>(values: T[], transform: (value: T) => R): R[] {
  let result: R[] = [];
  for (let value of values) {
    result.push(transform(value));
  }
  return result;
}

let lengths: number[] = mapValues<string, number>(['ark', 'guide'], (value: string): number => {
  return value.length;
});
```

For a fuller discussion of generic constraints and type parameters, see `generics.md`.

## Practical Function Patterns

### Validation Helper

```typescript
function requirePositive(value: number): number {
  if (value <= 0) {
    throw new Error('Value must be positive');
  }
  return value;
}
```

### Formatter Function

```typescript
function formatPrice(amount: number, currency: string = 'USD'): string {
  return `${currency} ${amount.toFixed(2)}`;
}
```

### Predicate Function

```typescript
function isLongWord(value: string): boolean {
  return value.length >= 8;
}
```

These small, focused functions are often easier to test and reuse than one large procedure.

## ArkTS Restrictions That Affect Functions

ArkTS intentionally removes or narrows several TypeScript and JavaScript function features:

- nested function declarations are not supported
- function expressions are not supported; use arrow functions instead
- call signatures in object types are not supported
- destructuring parameters are not supported
- `any` and `unknown` are not supported
- declaring properties on functions is not supported
- `Function.call`, `Function.apply`, and `Function.bind` are not supported
- `this` is not supported in stand-alone functions or static methods
- return type inference is limited in some recursive and cross-calling cases, so explicit return types are preferred

This chapter does not teach JavaScript-specific patterns such as function hoisting, the `arguments` object, dynamic function properties, or dynamic rebinding of `this`, because those patterns do not match idiomatic ArkTS.

Instead of a nested function declaration:

```typescript
function printMessage(message: string): void {
  let write: (value: string) => void = (value: string): void => {
    console.info(value);
  };

  write(message);
}
```

Instead of a destructured parameter, read fields explicitly from a declared type:

```typescript
class Point {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

function drawPoint(point: Point): void {
  console.info(`${point.x}, ${point.y}`);
}
```

Instead of writing a callable object type with a call signature, use a class with a regular method:

```typescript
class TextFormatter {
  prefix: string;

  constructor(prefix: string) {
    this.prefix = prefix;
  }

  format(value: string): string {
    return `${this.prefix}: ${value}`;
  }
}
```

Instead of dynamic function invocation helpers, call the function directly with well-typed arguments:

```typescript
function greetUser(name: string): void {
  console.info(`Hello, ${name}`);
}

greetUser('ArkTS');
```

Functions also appear as class methods. For instance-specific behavior and the supported use of `this`, see `methods.md`.
