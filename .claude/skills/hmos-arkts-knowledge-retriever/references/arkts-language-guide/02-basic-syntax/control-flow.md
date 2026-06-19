# Control Flow

Direct the order in which a program evaluates statements and expressions.

Control flow determines which code runs, how often it runs, and when execution stops or changes direction. Every program depends on it: a parser chooses between branches, a validator exits early on invalid input, and a loop processes each item in a collection one by one.

ArkTS provides familiar control-flow tools such as `if`, `switch`, `for`, and `while`, but it also encourages an explicit style that works well with static typing. Conditions should be clear, nullable values should be checked deliberately, and loop structure should match the shape of the data. Several dynamic JavaScript and TypeScript patterns are also restricted, so it is important to write branches and loops in a way that makes both runtime behavior and type intent obvious.

## Blocks and Statement Scope

A block groups statements inside braces:

```typescript
{
  let stage: string = 'parse';
  console.info(stage);
}
```

Variables declared with `let` and `const` are scoped to the nearest block. This helps prevent accidental reuse and keeps temporary variables close to the code that needs them.

```typescript
let active: boolean = true;

if (active) {
  let message: string = 'Running';
  console.info(message);
}

// message is not visible here
```

This block-oriented style is one reason ArkTS requires `let` instead of `var`.

## Conditional Branches

Use `if` and `else` when execution depends on a boolean condition:

```typescript
let temperature: number = 26;

if (temperature > 30) {
  console.info('Hot');
} else if (temperature > 20) {
  console.info('Warm');
} else {
  console.info('Cool');
}
```

An `if` chain is often the clearest choice when:

- branches depend on different comparisons
- the number of cases is small
- each branch performs different logic

Keep the condition specific. Prefer direct checks such as `value !== null`, `count > 0`, or `status === 'ready'` over broad truthy-style conditions when the domain is wider than `boolean`.

### Explicit Boolean Conditions

When a variable already has type `boolean`, it can be used directly:

```typescript
let isReady: boolean = true;

if (isReady) {
  console.info('Start processing');
}
```

When the variable is not a boolean, prefer a condition that states the real intent:

```typescript
let retries: number = 0;

if (retries > 0) {
  console.info('Retry mode');
}
```

This is clearer than relying on JavaScript coercion rules.

Broad truthiness checks can hide real cases:

```typescript
function printTitle(title: string | null): void {
  if (title) {
    console.info(title);
  }
}
```

This skips both `null` and the empty string. If those cases mean different things, write the condition explicitly instead:

```typescript
function printTitle(title: string | null): void {
  if (title === null) {
    console.info('Missing title');
    return;
  }
  if (title.length === 0) {
    console.info('Empty title');
    return;
  }
  console.info(title);
}
```

## Nullable Checks

Nullable values often appear in real programs:

```typescript
let nickname: string | null = null;

if (nickname === null) {
  console.info('No nickname');
} else {
  console.info(nickname);
}
```

This style is better than a broad truthiness check because it distinguishes a missing value from a present but empty string.

```typescript
function displayName(name: string | null): string {
  if (name === null) {
    return 'Anonymous';
  }
  if (name.length === 0) {
    return 'Empty Name';
  }
  return name;
}
```

When `null` and `undefined` are both possible, check them deliberately before using the value further.

## Type Narrowing Through Control Flow

Control flow is not only about runtime behavior. It also affects what type a value can safely be treated as inside each branch.

For example, a function may accept two possible input types:

```typescript
function normalize(value: string | number): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  return value.toString();
}
```

Inside the first branch, `value` is treated as a `string`. In the final branch, it is treated as a `number`. This is a practical example of narrowing: the condition makes later code more specific.

Nullable checks narrow values too:

```typescript
function printLength(text: string | null): void {
  if (text === null) {
    console.info('No text');
    return;
  }

  console.info(text.length);
}
```

Early returns make these narrowed branches especially clear.

### Reachability and Control Flow Analysis

Control flow also affects what is reachable after a branch ends. If one branch returns or throws, later code can assume that branch is no longer possible:

```typescript
function formatInput(input: string | number): string {
  if (typeof input === 'string') {
    return input.trim();
  }

  return input.toString();
}
```

After the first `return`, the remaining path handles only the non-string case. This is one reason early exits often make ArkTS code easier to read: they reduce nesting and make the later path more specific.

The same idea works with nullable values:

```typescript
function requireText(text: string | null): string {
  if (text === null) {
    throw new Error('Text is required');
  }

  return text;
}
```

In the final `return`, `text` is treated as a non-null `string`.

## switch Statements

Use `switch` when several branches depend on the same value:

```typescript
let level: number = 2;

switch (level) {
  case 1:
    console.info('Beginner');
    break;
  case 2:
    console.info('Intermediate');
    break;
  case 3:
    console.info('Advanced');
    break;
  default:
    console.info('Unknown');
    break;
}
```

`switch` is especially useful when:

- many branches compare against one expression
- each branch is a distinct named case
- the value comes from an enum or a small set of literals

### `switch` with Enumerations

```typescript
enum Direction {
  Up,
  Down,
  Left,
  Right
}

function describe(direction: Direction): string {
  switch (direction) {
    case Direction.Up:
      return 'Move up';
    case Direction.Down:
      return 'Move down';
    case Direction.Left:
      return 'Move left';
    case Direction.Right:
      return 'Move right';
    default:
      return 'Unknown';
  }
}
```

This style keeps the decision logic compact and easy to scan.

### `switch` with Literal States

`switch` also works well for a small set of literal states:

```typescript
type JobState = 'queued' | 'running' | 'done';

function describeJob(state: JobState): string {
  switch (state) {
    case 'queued':
      return 'Waiting to start';
    case 'running':
      return 'Currently processing';
    case 'done':
      return 'Finished';
    default:
      return 'Unknown state';
  }
}
```

This keeps one decision value at the top and makes each case easy to scan.

### Fallthrough and `break`

Most `switch` branches should end with `break` or `return`:

```typescript
function feeLabel(code: number): string {
  switch (code) {
    case 200:
      return 'Success';
    case 404:
      return 'Missing';
    default:
      return 'Unhandled';
  }
}
```

Avoid accidental fallthrough unless it is deliberate and obvious.

## for Loops

The classic `for` loop is useful when the loop variable, stopping condition, and update step are all explicit:

```typescript
for (let i = 0; i < 3; i++) {
  console.info(i);
}
```

This loop style is especially appropriate for:

- arrays that need index-based access
- counters
- generated numeric sequences
- nested loops over matrix-style data

### Counting with `for`

```typescript
for (let i = 1; i <= 5; i++) {
  console.info(`Step ${i}`);
}
```

When the count matters more than the values being traversed, a classic `for` loop is often the clearest tool.

### `for...of`

Use `for...of` when traversing array elements or other iterable values:

```typescript
let names: string[] = ['Anna', 'Ben', 'Cara'];
for (let name of names) {
  console.info(name);
}
```

`for...of` communicates that the loop depends on the values themselves rather than their indices.

Use it when:

- you do not need the numeric index
- the loop reads each value in order
- the code should emphasize data rather than positions

### Choosing the Right Loop

Choose the loop form that matches the shape of the work:

- use `for` when indices, counters, or multiple update expressions matter
- use `for...of` when the values themselves matter most
- use `while` when repetition depends on changing state
- use `do...while` when the body must run at least once

Choosing the loop to match the data usually produces the clearest control flow.

### `for...in` Is Not Part of ArkTS Loop Style

JavaScript often teaches `for...in`, but ArkTS does not support it:

```typescript
let values: string[] = ['1.0', '2.0', '3.0'];

for (let i = 0; i < values.length; i++) {
  console.info(values[i]);
}
```

When you need indices, use an indexed `for` loop. When you only need values, use `for...of`.

## while Loops

Use `while` when the number of iterations is not known in advance:

```typescript
let remaining: number = 3;

while (remaining > 0) {
  console.info(remaining);
  remaining--;
}
```

`while` is a good fit when repetition depends on state that changes inside the loop body:

```typescript
let attempts: number = 0;
let connected: boolean = false;

while (!connected && attempts < 3) {
  attempts++;
  connected = attempts === 3;
}
```

Make sure the loop condition can eventually become false. Otherwise, the loop will not terminate.

### `do...while`

`do...while` guarantees that the body runs at least once:

```typescript
let value: number = 0;

do {
  console.info(value);
  value++;
} while (value < 3);
```

Use this form only when one execution must happen before the condition is tested.

## break and continue

Use `break` to leave a loop immediately:

```typescript
for (let i = 0; i < 10; i++) {
  if (i === 4) {
    break;
  }
  console.info(i);
}
```

Use `continue` to skip the current iteration:

```typescript
for (let i = 0; i < 5; i++) {
  if (i === 2) {
    continue;
  }
  console.info(i);
}
```

These statements are often clearer than deeply nested conditionals because they keep the main path easy to read.

### Choosing Between `break` and Early Return

Inside loops:

- use `break` when work continues after the loop
- use `return` when the whole function should end

```typescript
function findFirstEven(values: number[]): number {
  for (let value of values) {
    if (value % 2 === 0) {
      return value;
    }
  }
  return -1;
}
```

This pattern is usually clearer than storing an intermediate result and finishing the function later.

## Early Exit Patterns

Sometimes the clearest control flow is to leave early instead of nesting more deeply:

```typescript
function describeScore(score: number): string {
  if (score < 0) {
    return 'invalid';
  }
  if (score < 60) {
    return 'failing';
  }
  if (score < 90) {
    return 'passing';
  }
  return 'excellent';
}
```

Early returns help when:

- invalid input should stop work immediately
- several special cases exist
- the "main path" should remain visually simple

This approach pairs well with validation and nullable checks:

```typescript
function requireName(name: string | null): string {
  if (name === null) {
    throw new Error('Name is required');
  }
  if (name.trim().length === 0) {
    throw new Error('Name cannot be empty');
  }
  return name;
}
```

## Control Flow in Error Handling

Exceptions also change control flow:

```typescript
function requirePositive(value: number): number {
  if (value <= 0) {
    throw new Error('Value must be positive');
  }
  return value;
}

try {
  console.info(requirePositive(3));
} catch (error) {
  console.info('Validation failed');
}
```

When an error is thrown, normal execution stops and control transfers to the nearest matching `catch` block. This makes exception handling part of control flow, not a separate concept.

Use exceptions for genuinely exceptional situations such as invalid state, failed parsing, or unavailable resources. Do not use them as a replacement for ordinary branching.

`finally` also affects control flow because it runs whether or not an error occurs:

```typescript
function readSettings(): void {
  console.info('Open settings');
  try {
    console.info('Read settings');
  } catch (error) {
    console.info('Read failed');
  } finally {
    console.info('Close settings');
  }
}
```

Use `finally` for cleanup such as closing resources or resetting temporary state.

ArkTS is stricter than JavaScript about thrown values. Throw `Error` objects or subclasses of `Error`, not arbitrary strings or numbers.

For more on exceptions, see `error-handling.md`.

## Common Loop Patterns

### Searching for a Value

```typescript
let targets: string[] = ['parse', 'check', 'emit'];
let found: boolean = false;

for (let item of targets) {
  if (item === 'check') {
    found = true;
    break;
  }
}
```

### Counting Matches

```typescript
let data: number[] = [1, 2, 3, 4, 5, 6];
let evenCount: number = 0;

for (let value of data) {
  if (value % 2 === 0) {
    evenCount++;
  }
}
```

### Building a Filtered Result

```typescript
let source: number[] = [1, 2, 3, 4, 5];
let result: number[] = [];

for (let value of source) {
  if (value % 2 !== 0) {
    continue;
  }
  result.push(value);
}
```

### Nested Loops

```typescript
let rows: number[][] = [
  [1, 2],
  [3, 4]
];

for (let i = 0; i < rows.length; i++) {
  for (let j = 0; j < rows[i].length; j++) {
    console.info(rows[i][j]);
  }
}
```

Nested loops are useful for matrices, grids, and grouped collections, but they increase complexity quickly. Keep the inner body short when possible.

## ArkTS Restrictions That Affect Control Flow

Several TypeScript and JavaScript forms should not be taught as ArkTS control-flow patterns:

- `for...in` is not supported
- destructuring declarations and assignments are not supported
- the comma operator is supported only in `for` loop headers
- the `in` operator is not supported
- catch-clause type annotations are not supported
- `throw` accepts only `Error` objects or subclasses

### Replace `for...in` with `for` or `for...of`

For arrays and other iterables, use `for...of` or an indexed `for` loop:

```typescript
let values: string[] = ['1.0', '2.0', '3.0'];
for (let value of values) {
  console.info(value);
}
```

If you need element positions, use an index instead:

```typescript
let values: string[] = ['1.0', '2.0', '3.0'];
for (let i = 0; i < values.length; i++) {
  console.info(`${i}: ${values[i]}`);
}
```

### Avoid Destructuring in Branches and Loops

When accessing grouped data, avoid destructuring and use explicit indexing or named properties instead:

```typescript
let pair: number[] = [10, 20];
let first: number = pair[0];
let second: number = pair[1];
console.info(first + second);
```

### Do Not Use `in` for Dynamic Property Checks

Do not use `in` to test object members. In ArkTS, object layout is explicit and stable, so control flow should usually branch on declared fields, known collection APIs, or `instanceof` where appropriate.

### Keep `catch` Clauses Untyped

ArkTS does not allow `catch` parameters to use `any` or `unknown` type annotations. Omit the type annotation entirely:

```typescript
try {
  console.info('Run task');
} catch (error) {
  console.info('Task failed');
}
```

### Throw `Error` Objects

Do not teach JavaScript patterns such as `throw 'failed'` or `throw 404`. In ArkTS, throw an `Error` instance instead:

```typescript
throw new Error('Validation failed');
```

These restrictions push ArkTS code toward a more explicit style. That explicitness is not just a limitation; it also makes examples easier to read and behavior easier to reason about.

For functions used in conditional logic, see `functions.md`. For boolean, comparison, and nullish operators used in conditions, see `advanced-operators.md`.
