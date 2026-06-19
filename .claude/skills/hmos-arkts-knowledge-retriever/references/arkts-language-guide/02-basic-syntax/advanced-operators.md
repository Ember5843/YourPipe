# Advanced Operators

Use operators to build expressions that compute, compare, combine, and update values.

Operators are part of everyday ArkTS code: arithmetic, comparison, logical conditions, nullish handling, and property access all depend on them. ArkTS keeps many familiar JavaScript operators, but it intentionally narrows several behaviors so that the code remains statically typed and predictable.

This chapter focuses on the operators that show up frequently in real ArkTS code and on the rules that make their behavior easier to reason about.

## Arithmetic Operators

Arithmetic operators work on numeric values:

```typescript
let a: number = 8;
let b: number = 3;

console.info(a + b); // 11
console.info(a - b); // 5
console.info(a * b); // 24
console.info(a / b); // 2.666...
console.info(a % b); // 2
```

Use these operators for ordinary numeric calculations.

Arithmetic expressions are often easier to read when intermediate meaning is visible:

```typescript
let width: number = 4;
let height: number = 6;
let area: number = width * height;
console.info(area); // 24
```

## Unary Numeric Operators

Unary `+`, `-`, and `~` apply to numeric values:

```typescript
let value: number = 5;
console.info(+value); // 5
console.info(-value); // -5
console.info(~value); // -6
```

In ArkTS, these operators are intentionally restricted. They do not perform JavaScript-style string coercion.

That means code such as this should be avoided:

```typescript
// let text: string = '5';
// let result = +text;
```

Use explicit conversion instead:

```typescript
let text: string = '5';
let result: number = Number.parseInt(text, 10);
console.info(result);
```

## Assignment Operators

Assignment stores a value in a variable:

```typescript
let count: number = 1;
count = 2;
```

Compound assignment combines an operation with reassignment:

```typescript
let total: number = 10;
total += 5;
total *= 2;
console.info(total); // 30
```

These operators help keep update logic short and readable.

Common compound assignments include:

- `+=`
- `-=`
- `*=`
- `/=`
- `%=`

Use them when the updated value is conceptually "the old value, adjusted".

Bitwise operators also have compound forms:

```typescript
let flags: number = 0b0101;
flags |= 0b0010;
flags &= 0b0111;
console.info(flags); // 7
```

Common bitwise compound assignments include:

- `&=`
- `|=`
- `^=`
- `<<=`
- `>>=`

## Comparison Operators

Comparison operators produce boolean values:

```typescript
let left: number = 10;
let right: number = 20;

console.info(left < right);   // true
console.info(left <= right);  // true
console.info(left > right);   // false
console.info(left >= right);  // false
console.info(left === right); // false
console.info(left !== right); // true
```

Prefer `===` and `!==` in examples and production code. They communicate exact comparison more clearly than looser JavaScript equality rules.

Comparison operators are commonly used in:

- validation logic
- loop conditions
- sorting and ranking logic
- state transitions

## Logical Operators

Logical operators combine boolean expressions:

```typescript
let isReady: boolean = true;
let hasPermission: boolean = false;

console.info(isReady && hasPermission); // false
console.info(isReady || hasPermission); // true
console.info(!isReady);                 // false
```

Logical operators are often used in conditions and guard-style checks.

### Short-Circuit Evaluation

Logical expressions are evaluated from left to right and may stop early:

```typescript
let enabled: boolean = false;

if (enabled && 10 / 2 > 1) {
  console.info('reachable only when enabled is true');
}
```

Short-circuit behavior is useful, but expressions should still stay readable. Avoid hiding too much control flow inside one dense boolean expression.

## Conditional Operator

The conditional operator chooses one of two values:

```typescript
let score: number = 85;
let result: string = score >= 60 ? 'pass' : 'fail';
console.info(result);
```

It is useful for short value-producing branches. For longer logic, use `if` statements instead.

Good use:

```typescript
let label: string = score >= 90 ? 'excellent' : 'standard';
```

Poor use:

- long nested conditions
- multi-step side effects
- complex branching that hides intent

## String Concatenation and Interpolation

The `+` operator can concatenate strings:

```typescript
let first: string = 'Ark';
let second: string = 'TS';
let full: string = first + second;
console.info(full); // ArkTS
```

Template literals are often easier to read when values of different types are involved:

```typescript
let count: number = 3;
console.info(`Count: ${count}`);
```

Use string concatenation for very small joins, and prefer interpolation when the result is a larger sentence or mixed-type output.

## Bitwise Operators

Bitwise operators work on the individual bits of numeric values. They are useful for masks, flags, and compact state encoding.

Common bitwise operators are:

- `&` for bitwise AND
- `|` for bitwise OR
- `^` for bitwise XOR
- `~` for bitwise NOT
- `<<` for left shift
- `>>` for right shift

Example:

```typescript
let left: number = 0b1100;
let right: number = 0b1010;

console.info(left & right); // 8  -> 0b1000
console.info(left | right); // 14 -> 0b1110
console.info(left ^ right); // 6  -> 0b0110
console.info(~left);        // bitwise inverse
```

Shift operators move bits left or right:

```typescript
let value: number = 4; // 0b0100

console.info(value << 1); // 8
console.info(value << 2); // 16
console.info(value >> 1); // 2
```

Bitwise code is easiest to maintain when the meaning of each bit is documented:

```typescript
let readFlag: number = 0b0001;
let writeFlag: number = 0b0010;

let permissions: number = readFlag | writeFlag;
let canWrite: boolean = (permissions & writeFlag) !== 0;
console.info(canWrite); // true
```

Prefer named masks over unexplained numeric literals. This makes flag-based expressions easier to review and safer to update later.

## Nullish Coalescing

Use `??` to provide a default only when the left side is `null` or `undefined`:

```typescript
let nickname: string | null = null;
let visibleName: string = nickname ?? 'Guest';
console.info(visibleName);
```

This is especially useful when the missing-value case is valid and explicit.

`??` differs from broad truthy logic because it does not replace meaningful values like `''` or `0`.

```typescript
let customLabel: string = '';
let label: string = customLabel ?? 'Default';
console.info(label); // ''
```

## Optional Chaining

Optional chaining safely accesses a property when the receiver may be absent:

```typescript
class Profile {
  nickname: string | null = null;
}

let profile: Profile | null = new Profile();
let nicknameLength: number | undefined = profile?.nickname?.length;
console.info(nicknameLength);
```

This avoids repeated null checks for simple access chains.

Use optional chaining for:

- nullable object references
- short access sequences
- derived reads where missing data should simply stop the chain

If the logic becomes more important than the access itself, explicit `if` checks are usually clearer.

## Operator Precedence

Some expressions need parentheses for clarity:

```typescript
let result: number = (2 + 3) * 4;
console.info(result); // 20
```

Even when the precedence rules are known, parentheses often make examples easier to read.

Prefer clarity over cleverness:

```typescript
let valid: boolean = (score > 60 && attempts < 3) || isAdmin;
```

The extra grouping helps the reader see the intended logic immediately.

## Property and Element Access

Dot syntax accesses named properties:

```typescript
class Point {
  x: number = 1;
  y: number = 2;
}

let point: Point = new Point();
console.info(point.x);
```

Bracket syntax accesses array elements:

```typescript
let values: number[] = [10, 20, 30];
console.info(values[1]); // 20
```

In ArkTS, bracket access should follow declared types rather than dynamic object patterns.

## Expression Clarity Guidelines

Operators are compact, but compact code is not always clear code.

Prefer:

- one meaningful expression over several tiny temporary steps when the result stays readable
- parentheses when precedence may be misread
- explicit conversion instead of implicit coercion
- named variables when an expression becomes dense

For example:

```typescript
let subtotal: number = 80;
let tax: number = 8;
let total: number = subtotal + tax;
```

This is often easier to understand than one oversized expression with several unrelated operations.

## ArkTS Restrictions That Affect Operators and Expressions

Several JavaScript and TypeScript operators or usages are restricted in ArkTS:

- unary `+`, `-`, and `~` work only on numeric values
- `delete` is not supported
- `in` is not supported
- destructuring assignment is not supported
- destructuring variable declarations are not supported
- spread is supported only in limited array-oriented scenarios
- the comma operator is supported only in `for` loops
- `typeof` is allowed in expressions, not in type positions
- `instanceof` works only with reference-type instances on the left side

### Do Not Use `delete`

ArkTS objects have an explicit, stable layout, so deleting properties is not part of the language model:

```typescript
class Device {
  name: string = 'Phone';
}
```

Do not teach patterns like:

```typescript
// let device: Device = new Device();
// delete device.name;
```

If a field may be absent, model that with `null`, a default value, or a different data structure.

### Do Not Use `in`

The `in` operator is not supported in ArkTS. Do not use it to probe object layout dynamically.

Prefer:

- declared properties
- `instanceof` for class hierarchies
- explicit collection APIs such as `Map.has()`

### Use `instanceof` Only with Reference Values

ArkTS supports `instanceof`, but it is narrower than in TypeScript and JavaScript.

The left side must be a reference-type instance such as an object, array, or function. Primitive values are not valid there in ArkTS.

```typescript
class Animal {}
class Cat extends Animal {}

let animal: Animal = new Cat();
console.info(animal instanceof Cat); // true
```

Avoid JavaScript-style examples such as checking whether a primitive number is an instance of `Number`. In ArkTS, that pattern is a compile-time error instead of a runtime `false`.

Detailed narrowing patterns that combine `instanceof` with `as` are covered in `type-casting.md`.

### Do Not Use Destructuring Assignment

ArkTS does not support destructuring assignment.

Do not teach patterns like:

```typescript
// let pair: number[] = [1, 2];
// let first = 0;
// let second = 0;
// [first, second] = pair;
```

Use explicit indexing or temporary variables instead:

```typescript
let pair: number[] = [1, 2];
let first: number = pair[0];
let second: number = pair[1];
```

When swapping values, keep the execution order explicit:

```typescript
let first: number = 1;
let second: number = 2;
let temporary: number = first;
first = second;
second = temporary;
```

### Do Not Use Destructuring Variable Declarations

ArkTS also does not support destructuring directly in variable declarations.

Prefer explicit property access:

```typescript
class Point {
  x: number = 0;
  y: number = 0;
}

let point: Point = new Point();
let x: number = point.x;
let y: number = point.y;
```

This style is more explicit and fits ArkTS's nominal, statically typed model.

### Use Spread Only in Supported Array Scenarios

ArkTS supports spread only in limited array-oriented cases. In practice, this means you should treat spread as an array convenience, not as a general object manipulation tool.

Array copy remains straightforward:

```typescript
let original: number[] = [1, 2, 3];
let copied: number[] = [...original];
console.info(copied[1]); // 2
```

For function calls, prefer explicit arguments unless the call site is already known to match an array-based spread pattern supported by ArkTS:

```typescript
function logNumbers(x: number, y: number, z: number): void {
  console.info(`${x}, ${y}, ${z}`);
}

let numbers: number[] = [1, 2, 3];
logNumbers(numbers[0], numbers[1], numbers[2]);
```

Do not use object spread patterns to create reshaped objects. Prefer constructors, class initialization, or explicit property assignment.

### Use the Comma Operator Only Where ArkTS Allows It

The comma operator is supported only in `for` loop headers. Avoid it elsewhere because it reduces readability and falls outside ArkTS's supported expression style.

```typescript
for (let i: number = 0, j: number = 0; i < 3; ++i, j += 2) {
  console.info(`${i}, ${j}`);
}
```

Outside a `for` loop header, write the steps as separate statements.

### Use `typeof` Only in Expression Contexts

ArkTS allows `typeof` in ordinary expressions:

```typescript
let value: string | number = 3;
console.info(typeof value); // number
```

However, ArkTS does not support TypeScript-style type queries such as `let other: typeof value`.

### Prefer Explicit Conversion

Instead of implicit coercion:

```typescript
let text: string = '5';
let value: number = Number.parseInt(text, 10);
let negative: number = -value;
console.info(negative); // -5
```

Instead of deleting a property or probing dynamic object layout, represent the missing state explicitly with `null`, a default value, or a more suitable container such as `Map`.

These restrictions are not arbitrary. They keep ArkTS expressions explicit, statically meaningful, and easier to maintain.

For operators used in conditions and loops, see `control-flow.md`. For casts and narrowing related to `instanceof` and `typeof`, see `type-casting.md`.
