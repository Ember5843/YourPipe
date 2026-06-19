# Generics

Write reusable code that works across several types without losing type safety.

Generics allow a function, class, or interface to express a relationship between types instead of hard-coding one specific type. They are one of the most useful tools for building reusable ArkTS APIs, especially for containers, lookup utilities, and transformation functions.

The key idea is simple: instead of saying "this works only for strings" or "this works only for numbers", generic code says "this works for any type, and I will preserve the relationship between the input type and the output type". That gives you reuse without throwing away type information.

## Why Generics Matter

Without generics, the same logic often has to be repeated for different types:

```typescript
function firstString(items: string[]): string | undefined {
  return items[0];
}

function firstNumber(items: number[]): number | undefined {
  return items[0];
}
```

These functions are structurally the same. Generics let one definition cover both cases:

```typescript
function firstElement<T>(items: T[]): T | undefined {
  return items[0];
}
```

This is the core reason generics exist: one algorithm can stay reusable while the type remains precise.

Another simple example is an identity-style function:

```typescript
function identity<T>(value: T): T {
  return value;
}

let text: string = identity<string>('ArkTS');
let count: number = identity<number>(42);
```

The function does not just accept "some value". It preserves the exact type relationship between the argument and the result.

## Generic Functions

Add a type parameter in angle brackets:

```typescript
function firstElement<T>(items: T[]): T | undefined {
  return items[0];
}

let firstName: string | undefined = firstElement<string>(['Ada', 'Grace']);
let firstValue: number | undefined = firstElement<number>([10, 20]);
```

The type parameter `T` connects the input type and the output type. If the input array holds `string`, the result is `string | undefined`; if it holds `number`, the result is `number | undefined`.

Good generic functions usually make one or more type relationships visible:

- input element type to output element type
- callback input type to callback result type
- stored value type to retrieved value type

## Working with Generic Type Variables

Inside a generic function, a type parameter stands for an unknown type. That means the code can only use operations that are valid for every possible type matching the signature.

For example, this generic function is fine:

```typescript
function echo<T>(value: T): T {
  return value;
}
```

But if the function tries to use a property that is not guaranteed to exist, the code is no longer valid for all `T`.

To access `.length`, the function must say so in the type:

```typescript
function logArrayLength<T>(items: T[]): T[] {
  console.info(items.length);
  return items;
}
```

This works because arrays always have a `length` property. The important rule is: generic code can only use capabilities that are visible in the declared type.

## Type Argument Inference

ArkTS can often infer the type argument from the call:

```typescript
let nameResult: string | undefined = firstElement(['A', 'B']);
let numberResult: number | undefined = firstElement([1, 2, 3]);
```

Inference is convenient, but explicit type arguments can improve readability when a call site is complex:

```typescript
let explicitResult: string | undefined = firstElement<string>(['x', 'y']);
```

Use explicit type arguments when:

- inference is unclear to the reader
- the call involves several generic parameters
- you want to make the intended type obvious in documentation examples

## Generic Functions with Several Type Parameters

Some reusable functions relate more than one type:

```typescript
function mapValues<Input, Output>(
  items: Input[],
  transform: (value: Input) => Output
): Output[] {
  let result: Output[] = [];
  for (let item of items) {
    result.push(transform(item));
  }
  return result;
}

let lengths: number[] = mapValues<string, number>(
  ['ArkTS', 'Guide'],
  (value: string): number => {
    return value.length;
  }
);
```

This pattern appears frequently in collection processing.

Here, the generic parameters express two different roles:

- `Input` is the original item type
- `Output` is the transformed item type

## Generic Classes

Classes can also be generic:

```typescript
class Box<T> {
  value: T;

  constructor(value: T) {
    this.value = value;
  }
}

let textBox: Box<string> = new Box<string>('hello');
let countBox: Box<number> = new Box<number>(3);
```

The same class definition can now store different kinds of values while remaining type-safe.

Generic classes are useful for:

- wrappers
- containers
- caches
- reusable state holders

Another example:

```typescript
class Pair<T> {
  first: T;
  second: T;

  constructor(first: T, second: T) {
    this.first = first;
    this.second = second;
  }
}
```

## Generic Interfaces

Interfaces can declare type parameters too:

```typescript
interface Repository<T> {
  save(item: T): void;
  load(): T[];
}
```

This is useful for service layers, data adapters, and typed infrastructure code.

Generic interfaces work especially well when several implementations should follow the same type relationship:

```typescript
interface Converter<Input, Output> {
  convert(value: Input): Output;
}
```

## Constraints

Use `extends` to limit the kinds of types a generic parameter can accept:

```typescript
interface HasLength {
  length: number;
}

function longer<T extends HasLength>(a: T, b: T): T {
  if (a.length >= b.length) {
    return a;
  }
  return b;
}
```

Constraints let the generic code rely on a known capability such as `.length`.

Without the constraint, the function would not be allowed to access `length` because not every type has that property.

### Why Constraints Help

Constraints are useful when the algorithm needs a specific capability but should still work across multiple concrete types:

```typescript
function printLength<T extends HasLength>(value: T): void {
  console.info(value.length);
}
```

This works for strings, arrays, and other values that expose `length`.

## Returning the Same Constrained Type

When a generic function returns `T`, it promises to return the same concrete type that came in, not just any value that satisfies the constraint.

That distinction matters:

```typescript
interface HasLength {
  length: number;
}

function ensureMinimumLength<T extends HasLength>(value: T, minimum: number): T {
  if (value.length >= minimum) {
    return value;
  }

  // Not valid: this is only a HasLength value, not necessarily the same T.
  // return { length: minimum };

  return value;
}
```

If the caller passes a `string[]`, the return type is still `string[]`. If the caller passes a custom class that has a `length` field, the return type is that same class type. Returning some other object with only a `length` property would break that promise.

Use constraints to describe required capabilities, but remember that `T extends SomeType` still means "one specific subtype chosen by the caller".

## Generic APIs and Collections

Generics are especially natural with collection types:

```typescript
function takeFirstTwo<T>(items: T[]): T[] {
  let result: T[] = [];
  for (let i = 0; i < items.length && i < 2; i++) {
    result.push(items[i]);
  }
  return result;
}
```

This function works for `string[]`, `number[]`, and arrays of user-defined classes alike.

Another common pattern is generic search:

```typescript
function containsValue<T>(items: T[], target: T): boolean {
  for (let item of items) {
    if (item === target) {
      return true;
    }
  }
  return false;
}
```

Generics are often the simplest way to write reusable array and map helpers without repeating the same logic for every element type.

## Practical Generic Patterns

### Generic Wrapper

```typescript
class Result<T> {
  value: T;

  constructor(value: T) {
    this.value = value;
  }
}
```

### Generic Mapping Helper

```typescript
function toStrings<T>(items: T[]): string[] {
  let result: string[] = [];
  for (let item of items) {
    result.push(item.toString());
  }
  return result;
}
```

### Generic Repository Contract

```typescript
interface Store<T> {
  add(item: T): void;
  all(): T[];
}
```

These are practical examples of where generics improve reuse without making the code harder to read.

## Guidelines for Writing Good Generic Code

Generic code is most useful when:

- the same logic genuinely applies to several types
- the type parameter appears in more than one meaningful position
- constraints are added only when the logic needs them
- the generic relationship is easy to explain

If a function works for only one concrete type, a non-generic definition is usually clearer.

Also prefer:

- fewer type parameters over many unnecessary ones
- meaningful generic names like `Input` and `Output` when they improve clarity
- straightforward signatures over clever type tricks

Two practical rules help keep generic APIs readable and inferable:

- use the type parameter itself when possible, instead of immediately replacing it with a broader constrained type
- if a type parameter appears in only one meaningful position, reconsider whether the function really needs to be generic

For example, this generic function is usually unnecessary:

```typescript
function greet<T extends string>(name: T): void {
  console.info('Hello, ' + name);
}
```

This simpler version is often better:

```typescript
function greet(name: string): void {
  console.info('Hello, ' + name);
}
```

## ArkTS Restrictions That Affect Generics

ArkTS supports practical generics, but it does not support the full TypeScript type-manipulation toolbox:

- conditional types are not supported
- `infer` is not supported
- mapped types are not supported
- indexed access types are not supported
- only a subset of TypeScript utility types is supported
- generic type inference is more limited than in TypeScript
- structural typing is not supported

That means ArkTS generics should focus on:

- reusable functions
- reusable classes
- reusable interfaces
- simple constraints

### Generic Type Inference Is Limited

ArkTS can infer generic type arguments from function parameters in many common cases:

```typescript
function choose<T>(left: T, right: T): T {
  return Math.random() < 0.5 ? left : right;
}

let value: number = choose(10, 20);
```

However, ArkTS does not infer a generic type argument from the return type alone:

```typescript
function makeValue<T>(): T {
  return 'hello' as T;
}

let message: string = makeValue<string>();
```

When the compiler cannot determine `T` from the arguments, write the type argument explicitly.

### Prefer Explicit Contracts Over Structural Assumptions

TypeScript often allows generic code to rely on structural compatibility between unrelated types. ArkTS does not support structural typing, so generic APIs should use explicit interfaces, inheritance, or declared class types when a shared contract is required.

For example, this kind of contract is clear and works well in ArkTS:

```typescript
interface Named {
  name: string;
}

function printName<T extends Named>(value: T): void {
  console.info(value.name);
}
```

The shared capability is declared explicitly instead of being left to structural comparison.

### Prefer Value-Level Reuse Over Type-Level Tricks

For ArkTS documentation and production code, prefer straightforward generics over advanced type-level programming. A readable generic function or generic class is usually better than a clever but hard-to-maintain type construction.

This is the style to aim for:

```typescript
function lastElement<T>(items: T[]): T | undefined {
  if (items.length === 0) {
    return undefined;
  }
  return items[items.length - 1];
}
```

Keep generic APIs practical and easy to explain.

For generic contracts, see `interfaces.md`. For generic arrays and maps used in everyday code, see `collection-types.md`.
