# Enumerations

Model a fixed set of related choices with `enum`.

An enumeration defines a type whose values come from a known, limited set of members. Enums make code easier to read than scattered numeric constants or repeated string literals because each case receives a descriptive name and belongs to an explicit type.

Enums are a good fit when the set of valid values is closed and stable. Instead of passing raw numbers or strings around, the code can name each case directly and let the type system enforce that only the intended values are used.

## Declaring an Enumeration

Use the `enum` keyword to declare an enumeration:

```typescript
enum Direction {
  Up,
  Down,
  Left,
  Right
}
```

Each member is accessed through the enum type:

```typescript
let heading: Direction = Direction.Up;
```

The type `Direction` now documents that only these four values are valid.

## Why Enums Help

Enums are useful because they make code say *what a value means*, not just *what its raw representation is*.

Compare:

```typescript
enum Status {
  Ready,
  Running,
  Completed
}

let current: Status = Status.Ready;
```

This is usually clearer than:

```typescript
let currentStatus: number = 0;
```

With the enum version, the reader does not need to remember what `0` means.

## Numeric Enumerations

If you do not assign explicit values, numeric members are given sequential values:

```typescript
enum Status {
  Ready,
  Running,
  Completed
}
```

This is often enough when the numeric values themselves are not important and only the named cases matter.

You can also assign explicit numeric values:

```typescript
enum HttpStatus {
  Ok = 200,
  NotFound = 404,
  InternalError = 500
}
```

Explicit numeric values are useful when the enum corresponds to:

- an external protocol
- stored data
- operating-system constants
- network status codes

## String Enumerations

Use string-valued members when the textual representation matters:

```typescript
enum DisplayTheme {
  Light = 'light',
  Dark = 'dark',
  System = 'system'
}
```

String enums are often a good choice for:

- user preferences
- serialized configuration
- logs and diagnostics
- UI state values

String members can also make debugging easier because the values remain readable when printed.

## How Member Values Are Chosen

Enum member values should stay predictable and easy to understand.

For numeric enums, a member without an explicit initializer receives the next sequential value:

```typescript
enum Priority {
  Low = 1,
  Medium,
  High
}
```

In this example, `Priority.Medium` is `2` and `Priority.High` is `3`.

This works well when:

- the values must remain distinct
- the sequence itself is meaningful
- later code should not repeat the numbers manually

ArkTS also allows explicit compile-time initializers:

```typescript
enum FileAccess {
  None = 0,
  Read = 1,
  Write = 2,
  ReadWrite = 3
}
```

Keep enum initializers simple. In ArkTS:

- enum members must be initialized with compile-time expressions
- all explicitly written initializers in one enum must use the same type
- runtime-computed values should not be used

These rules keep the enum stable as a fixed set of named constants.

## `const enum`

Use `const enum` when the enum is a fixed set of compile-time constants and the code does not need to treat the enum as a runtime object.

```typescript
const enum LogLevel {
  Error = 1,
  Warn = 2,
  Info = 3
}

let level: LogLevel = LogLevel.Warn;
```

This is a good fit for:

- internal mode flags
- stable status codes
- shared constants used across many call sites

`const enum` members must also remain compile-time constants. Keep the declaration compact and avoid any initializer that depends on runtime evaluation.

## Using Enumerations in Variables and Properties

Enums work naturally in variables, class properties, and collections:

```typescript
class DownloadTask {
  state: Status = Status.Ready;
}

let themes: DisplayTheme[] = [DisplayTheme.Light, DisplayTheme.Dark];
```

This is useful when the state space should remain small and explicit.

A property typed as an enum clearly communicates that only the declared cases are allowed.

## Using Enumerations in Functions

Enums work naturally as parameter and return types:

```typescript
function isFinished(status: Status): boolean {
  return status === Status.Completed;
}

function defaultTheme(): DisplayTheme {
  return DisplayTheme.System;
}
```

This makes APIs self-documenting and keeps invalid values out of the function body.

Enums are especially good in function signatures when:

- the valid values are part of the API contract
- several call sites share the same choice set
- the function logic branches on a known set of cases

Another common use is to make a small closed set of modes explicit at API boundaries:

```typescript
enum OpenMode {
  Read = 'read',
  Write = 'write',
  Append = 'append'
}

function canModify(mode: OpenMode): boolean {
  return mode === OpenMode.Write || mode === OpenMode.Append;
}
```

This is clearer than accepting an unconstrained `string`, because the function contract names the exact valid choices.

## `switch` with Enumerations

Enums are especially useful in `switch` statements:

```typescript
function describeDirection(direction: Direction): string {
  switch (direction) {
    case Direction.Up:
      return 'Move upward';
    case Direction.Down:
      return 'Move downward';
    case Direction.Left:
      return 'Move left';
    case Direction.Right:
      return 'Move right';
    default:
      return 'Unknown';
  }
}
```

This pattern is easier to read than a series of unrelated numbers or strings because each branch names the meaning directly.

Another example:

```typescript
function describeStatus(status: Status): string {
  switch (status) {
    case Status.Ready:
      return 'Ready to start';
    case Status.Running:
      return 'In progress';
    case Status.Completed:
      return 'Finished';
    default:
      return 'Unknown';
  }
}
```

## Enumerations and Stored Data

Enums can be used to model finite state in classes:

```typescript
class Player {
  state: Status = Status.Ready;

  start(): void {
    this.state = Status.Running;
  }

  finish(): void {
    this.state = Status.Completed;
  }
}
```

This is often better than:

- raw numeric flags
- repeated string literals
- several loosely related booleans

If an object has a clearly bounded state machine, an enum is often a natural representation.

String enums are also useful when data must keep a stable textual form:

```typescript
enum SettingKey {
  Theme = 'theme',
  Language = 'language'
}

let defaults: Record<string, string> = {
  [SettingKey.Theme]: 'light',
  [SettingKey.Language]: 'en'
};
```

This keeps the keys centralized and avoids repeating unrelated string literals throughout the codebase.

## Choosing Between Enums and String Literals

Use an enum when:

- the valid values are fixed and part of the API
- several places in the code share the same choice set
- the code benefits from a named type
- you want one authoritative definition of the cases

Use plain string literals when the values are ad hoc or local to one small piece of code.

For example, an enum is a good choice for:

- download state
- user role
- UI theme
- protocol status code

An enum is a poor choice when:

- the set of values is open-ended
- values come from user input without a fixed closed list
- the values are only used once in a tiny local context

## Designing Good Enums

Good enums usually have:

- a small number of clearly named members
- members that belong to one conceptual domain
- stable meanings across the codebase
- values that do not need runtime mutation

If the value needs attached mutable state or complex behavior, a class is usually a better fit.

## ArkTS Restrictions That Affect Enumerations

ArkTS keeps enum syntax close to TypeScript, but some advanced TypeScript patterns should not be used:

- enum members should be initialized only with compile-time expressions
- all explicitly set enum initializers should be of the same type
- enum declaration merging is not supported
- dynamic enum construction is not part of ArkTS style
- object-as-enum patterns based on `as const` are not an ArkTS replacement for enums

### Keep Member Values Simple and Stable

This style is safe and explicit:

```typescript
enum BadgeSize {
  Small = 1,
  Medium = 2,
  Large = 3
}
```

And this style is also clear:

```typescript
enum DeployEnvironment {
  Dev = 'dev',
  Test = 'test',
  Prod = 'prod'
}
```

Avoid mixing member value types or relying on runtime-computed values for enum members.

For example, this TypeScript style should not be used in ArkTS:

```typescript
enum ResultCode {
  Ok = 0,
  Error = 'error'
}
```

Use one consistent representation instead:

```typescript
enum ResultCode {
  Ok = 'ok',
  Error = 'error'
}
```

Likewise, do not depend on runtime computation for enum values:

```typescript
enum BuildStage {
  Parse = 1,
  Analyze = 2,
  Emit = 3
}
```

### Do Not Merge Enum Declarations

Keep each enum compact and complete in one place:

```typescript
enum Role {
  Guest = 'guest',
  Member = 'member',
  Admin = 'admin'
}
```

Do not split one enum across multiple declarations.

### Do Not Rely on TypeScript-Only Enum Patterns

Some enum techniques described in general TypeScript references are not the right model for ArkTS documentation and examples:

- do not rely on heterogeneous enums
- do not rely on runtime-computed enum members
- do not rely on declaration merging
- do not replace enums with `as const` object patterns, because `as const` is not supported in ArkTS

When the valid values are fixed and shared across the program, prefer a normal `enum` or `const enum` with simple compile-time member values.

These restrictions keep enums simple, readable, and reliable as fixed sets of named values.

For branching logic with enums, see `control-flow.md`. For storing enum values in classes, see `properties.md`.
