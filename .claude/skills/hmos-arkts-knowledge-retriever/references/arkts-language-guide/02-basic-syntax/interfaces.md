# Interfaces

Describe shared contracts that classes and values are expected to follow.

An interface names a set of properties and methods that a type must provide. Interfaces are useful for expressing intent, documenting APIs, and reusing a common contract across several classes. They answer the question: "What capabilities must this value expose?"

In ArkTS, interfaces remain important, but they should be used with an explicit, contract-oriented mindset rather than a dynamic TypeScript "shape matches anything" mindset. An interface is a deliberate public agreement, not a loosely inferred object pattern.

## Declaring an Interface

Declare an interface with the `interface` keyword:

```typescript
interface Named {
  name: string;
}
```

This interface says that any conforming type must expose a `name` property of type `string`.

Interface names should reflect meaning rather than raw field shape. `Printable`, `Repository<T>`, and `Named` are usually better than names that only repeat implementation details.

## Implementing an Interface in a Class

A class implements an interface by providing all required members:

```typescript
interface Printable {
  print(): string;
}

class Report implements Printable {
  title: string;

  constructor(title: string) {
    this.title = title;
  }

  print(): string {
    return this.title;
  }
}
```

This makes the class's intended contract visible where the class is declared.

Use `implements` when:

- the class should promise a public capability
- several classes should expose the same API
- callers should depend on the contract rather than the concrete class

## Interfaces with Several Members

Interfaces may contain both properties and methods:

```typescript
interface UserProfile {
  id: string;
  name: string;
  isActive(): boolean;
}
```

Grouping related requirements under one interface can simplify function signatures and documentation.

A good interface usually describes one coherent role. If an interface starts mixing unrelated concerns, split it into smaller contracts.

## Extending Interfaces

One interface can extend another:

```typescript
interface Identified {
  id: string;
}

interface PersonLike extends Identified {
  name: string;
}
```

This is the standard ArkTS way to combine interface requirements.

Interface inheritance is useful when one contract is a specialized version of another:

```typescript
interface Timestamped {
  createdAt: string;
}

interface AuditRecord extends Timestamped {
  updatedAt: string;
}
```

This keeps shared requirements in one place without forcing shared implementation.

## Interfaces in APIs

Interfaces are especially useful in function parameters and return types:

```typescript
interface NamedItem {
  name: string;
}

function printName(item: NamedItem): void {
  console.info(item.name);
}
```

This keeps function signatures readable and avoids repeating the same set of members across several call sites.

Interfaces in APIs help when:

- several concrete classes should be accepted
- the caller only needs a small part of a larger type
- the implementation should be replaceable later

## Interfaces as Capability Contracts

Many interfaces describe a capability rather than a whole object:

```typescript
interface Closable {
  close(): void;
}

interface Resettable {
  reset(): void;
}
```

This style often works well because it keeps each contract narrow and composable.

A class can implement more than one interface:

```typescript
class EditorSession implements Closable, Resettable {
  close(): void {
    console.info('closed');
  }

  reset(): void {
    console.info('reset');
  }
}
```

## Property Requirements

Interfaces can require named properties with specific types:

```typescript
interface AccountSummary {
  id: string;
  balance: number;
}
```

This does not say how the value is stored internally. It only says what the public contract must expose.

Interfaces can also include `readonly` properties when callers should not assign them:

```typescript
interface SessionInfo {
  readonly id: string;
  userName: string;
}
```

The interface describes how the API should be used, not how the class is implemented internally.

Interfaces may also declare optional properties with `?`:

```typescript
interface PaintOptions {
  color: string;
  opacity?: number;
}
```

An optional property may be omitted by the caller, but if it is present it must still match the declared type.

When reading an optional property, handle the possibility that it is `undefined`:

```typescript
function describePaint(options: PaintOptions): string {
  if (options.opacity === undefined) {
    return options.color;
  }
  return `${options.color} (${options.opacity})`;
}
```

Optional properties are useful when a value has a few legitimate variants, but the core contract is still stable.

## Use Named Interfaces Instead of Inline Object Type Declarations

TypeScript often uses inline object type declarations in function parameters:

```typescript
// Common TypeScript style:
// function printPoint(point: { x: number; y: number }): void { ... }
```

ArkTS does not support using object literal type declarations in place. Declare a named interface or class instead:

```typescript
interface PointLike {
  x: number;
  y: number;
}

function printPoint(point: PointLike): void {
  console.info(`${point.x}, ${point.y}`);
}
```

This keeps the contract reusable, makes APIs easier to read, and matches ArkTS's requirement for explicit named types.

## Method Requirements

Interfaces can also require behavior:

```typescript
interface Formatter {
  format(value: string): string;
}
```

A class implementing this interface must provide a compatible `format()` method:

```typescript
class UppercaseFormatter implements Formatter {
  format(value: string): string {
    return value.toUpperCase();
  }
}
```

Method requirements are useful when callers depend on an operation rather than a particular data layout.

## Generic Interfaces

Interfaces can also use type parameters:

```typescript
interface Repository<T> {
  save(item: T): void;
  load(): T[];
}
```

Generic interfaces are useful for reusable service-style abstractions and typed containers.

Another example:

```typescript
interface Converter<Input, Output> {
  convert(value: Input): Output;
}
```

Generics let the interface stay reusable without losing the relationship between input and output types.

## Interfaces and Concrete Classes

Interfaces and classes serve different purposes:

- an interface defines requirements
- a class provides implementation and stored state

For example:

```typescript
interface Searchable {
  matches(text: string): boolean;
}

class TitleRecord implements Searchable {
  title: string;

  constructor(title: string) {
    this.title = title;
  }

  matches(text: string): boolean {
    return this.title.includes(text);
  }
}
```

Use an interface when you want code to depend on the capability. Use a class when you need real data and behavior packaged together.

## Interface Design Guidelines

Prefer interfaces that are:

- small and focused
- easy to explain in one sentence
- stable across several call sites
- centered on meaning rather than accidental field grouping

Good interfaces often describe roles such as:

- `Printable`
- `Closable`
- `Repository<T>`
- `Named`

If an interface becomes too broad, split it into smaller contracts instead of growing one large umbrella type.

## ArkTS Restrictions That Affect Interfaces

ArkTS interfaces are more restrictive than TypeScript interfaces in several important ways:

- structural typing is not supported
- indexed signatures are not supported
- call signatures in object types are not supported
- constructor signatures in interfaces are not supported
- declaration merging is not supported
- interfaces cannot extend classes
- classes cannot appear in an `implements` clause

### Do Not Treat Interfaces as Loose Shape Matching

In TypeScript, interface use often leans on structural compatibility. In ArkTS, two unrelated types should not be treated as interchangeable just because they happen to expose similar members.

Use an explicit relationship instead:

```typescript
interface Named {
  name: string;
}

class Customer implements Named {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}
```

This is clearer than assuming that any unrelated class with a `name` field should automatically count as the same kind of thing. If several types must be accepted through one API, define a shared interface and implement it explicitly.

### Do Not Use Indexed Signatures

Do not model dictionary-style dynamic data with interface index signatures:

```typescript
// Avoid TypeScript-style patterns such as:
// interface SettingsMap {
//   [key: string]: string;
// }
```

For dynamic key-value associations, use a `Map<K, V>` instead. For indexed sequential data, use arrays.

### Do Not Use Call Signatures in Interface-Like Object Types

TypeScript can describe callable objects with additional properties. ArkTS does not support this pattern.

```typescript
// Avoid TypeScript-style patterns such as:
// interface DescribableFunction {
//   description: string;
//   (value: number): boolean;
// }
```

If a value needs both state and behavior, use a class with a normal method:

```typescript
class ThresholdChecker {
  description: string;

  constructor(description: string) {
    this.description = description;
  }

  check(value: number): boolean {
    return value > 10;
  }
}
```

### Do Not Put Constructor Signatures in Interfaces

ArkTS does not support constructor signatures inside interfaces. If callers need a construction path, use:

- a concrete class
- a factory function
- a static method on a class

### Do Not Rely on Declaration Merging

Keep each interface declaration complete in one place. Do not spread one interface across multiple declarations.

### Interfaces Cannot Extend Classes

If shared implementation is needed, use class inheritance. If shared requirements are needed, use interface inheritance.

Convert class state that should become part of a contract into a separate interface:

```typescript
interface ControlState {
  state: number;
}

interface SelectableControl extends ControlState {
  select(): void;
}
```

### Avoid Conflicting Inherited Method Shapes

When one interface extends multiple interfaces, inherited members must remain compatible. Do not create a combined interface that inherits methods with the same parameter list but incompatible return types.

If two capabilities need different result shapes, give them different method names instead of trying to merge them into one ambiguous member.

### Classes Only Implement Interfaces

ArkTS does not allow a class to appear inside an `implements` clause.

Use:

- `extends` for class-to-class inheritance
- `implements` for class-to-interface conformance

### Be Careful with Object Literal Initialization

ArkTS can use object literals for some interface values when the target interface is explicit and contains only data properties:

```typescript
interface PointData {
  x: number;
  y: number;
}

let point: PointData = { x: 3, y: 4 };
```

However, do not rely on object literals to initialize interface-style values when the contract includes methods or other restricted patterns:

```typescript
interface Formatter {
  format(value: string): string;
}

class PlainFormatter implements Formatter {
  format(value: string): string {
    return value;
  }
}
```

For behavior-rich contracts, a class implementation is the clearest and safest ArkTS style.

These restrictions push ArkTS interface design toward explicit contracts with clear ownership and intent.

For shared implementation, use class inheritance. For shared requirements, use interfaces. For generic contract design, see `generics.md`.
