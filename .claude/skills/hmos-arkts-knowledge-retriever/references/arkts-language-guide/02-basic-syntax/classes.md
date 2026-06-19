# Classes

Define custom reference types that combine data and behavior.

Classes are one of the central building blocks of ArkTS programs. A class gives a type a name, defines the fields that every instance must contain, and attaches methods that operate on that data. When several values belong together and should move through a program as one unit, a class is often the clearest representation.

Classes are especially important in ArkTS because object layout is explicit and stable. Fields are declared in the class body, instances are created through constructors, and the public API of the type is visible in one place. This differs from JavaScript's more dynamic object model, where properties and methods are often added or reassigned later.

## Declaring a Class

Use the `class` keyword to define a class:

```typescript
class User {
  name: string = '';
  age: number = 0;
}
```

Create an instance with `new`:

```typescript
let user: User = new User();
user.name = 'Alice';
user.age = 20;
```

The class declaration describes what every `User` instance contains. This is one of the key reasons classes work well in ArkTS: the structure is declared up front instead of being assembled dynamically at runtime.

### Use Named Class Declarations

In ArkTS, a class is normally introduced with a named declaration:

```typescript
class Logger {
  prefix: string = '[App]';
}
```

This keeps the type easy to reference and makes the public model visible at the declaration site.

JavaScript and TypeScript also allow class expressions such as:

```typescript
// Avoid JavaScript-style patterns such as:
// const Logger = class { };
```

ArkTS does not support class literals. Declare a named class explicitly instead.

## Fields

Fields store per-instance data:

```typescript
class Point {
  x: number = 0;
  y: number = 0;
}
```

Each instance of `Point` has its own `x` and `y` values. Field declarations belong in the class definition itself, not somewhere else in the program.

### Field Initializers

Field initializers provide default values:

```typescript
class ConnectionOptions {
  host: string = 'localhost';
  port: number = 8080;
  secure: boolean = false;
}
```

Defaults are useful when a field has an obvious starting value. They also make the initial state of the type easy to understand without reading the constructor first.

### Fields Without Default Values

Some fields are only known when the instance is created:

```typescript
class Product {
  name: string;
  price: number;

  constructor(name: string, price: number) {
    this.name = name;
    this.price = price;
  }
}
```

In this case, the constructor is responsible for assigning all required fields.

## Creating Instances

An instance is created by calling the constructor with `new`:

```typescript
class Person {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

let person: Person = new Person('Grace');
```

Each call to `new` creates a distinct object:

```typescript
let first: Person = new Person('Ada');
let second: Person = new Person('Ada');

console.info(first === second); // false
```

The two instances may contain the same data, but they are still different objects.

Creating a class instance with `new` is the standard and clearest ArkTS pattern. In particular, classes with custom constructors, methods, or `readonly` fields should be created through their constructor rather than treated like ordinary object literals.

### Constructors Establish Valid State

One of the main jobs of a constructor is to guarantee that every new instance starts in a valid state:

```typescript
class Task {
  title: string;
  completed: boolean;

  constructor(title: string) {
    this.title = title;
    this.completed = false;
  }
}
```

This is better than creating an incomplete object and assigning required fields later.

### Do Not Treat Classes as Loose Object Shapes

In JavaScript and TypeScript, it is common to think of a class as "just an object with these fields". In ArkTS, classes are more explicit than that: they define a named reference type with declared members and constructor-based initialization.

For example, this is the intended class style:

```typescript
class ServerConfig {
  host: string;
  port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }
}

let config: ServerConfig = new ServerConfig('localhost', 8080);
```

This keeps class construction aligned with the declared type instead of relying on object-shape tricks.

## Accessing Members

Use dot syntax to read and write fields:

```typescript
let task: Task = new Task('Review guide');
console.info(task.title);

task.completed = true;
console.info(task.completed);
```

Dot syntax also works for methods and static members. Because ArkTS expects object layout to be known in advance, explicit member access is the normal pattern.

## Visibility

ArkTS supports the standard access modifiers:

- `public` for members visible everywhere
- `private` for members visible only inside the class
- `protected` for members visible inside the class and its subclasses

```typescript
class Account {
  public id: string;
  private balance: number = 0;

  constructor(id: string) {
    this.id = id;
  }

  public deposit(amount: number): void {
    this.balance += amount;
  }
}
```

Visibility helps separate a class's public API from its internal implementation details.

### Why Visibility Matters

Public members form the part of the class that other code is allowed to depend on. Private members support the implementation but should not be manipulated from the outside.

```typescript
class StepCounter {
  private count: number = 0;

  public increment(): void {
    this.count++;
  }

  public current(): number {
    return this.count;
  }
}
```

This keeps internal state changes under control.

## Methods on Classes

Classes usually combine stored data with behavior:

```typescript
class AreaBox {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }

  area(): number {
    return this.width * this.height;
  }
}

let rect: AreaBox = new AreaBox(4, 6);
console.info(rect.area()); // 24
```

Attaching behavior to the class makes it easier to keep related logic near the data it operates on.

For a deeper discussion of methods, see `methods.md`.

## Static Members

Use `static` for members that belong to the class itself rather than to each instance:

```typescript
class Temperature {
  static freezingPoint(): number {
    return 0;
  }
}

console.info(Temperature.freezingPoint());
```

Static members are useful for:

- constants closely tied to a type
- named factory-style helpers
- utility logic that conceptually belongs to the class

```typescript
class MathTools {
  static clamp(value: number, min: number, max: number): number {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
```

Call static members on the class, not on an instance.

## Abstract Classes

An abstract class defines a common base that is meant to be specialized by subclasses:

```typescript
abstract class BaseShape {
  abstract area(): number;
}

class AreaRectShape extends BaseShape {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    super();
    this.width = width;
    this.height = height;
  }

  area(): number {
    return this.width * this.height;
  }
}
```

Abstract classes are useful when several concrete classes should share a common contract or shared implementation, but the base type itself is incomplete.

### Abstract Classes Cannot Be Instantiated

An abstract class is a design-time base type, not a directly creatable one:

```typescript
abstract class MessageSource {
  abstract load(): string;
}

// Avoid patterns such as:
// let source = new MessageSource();
```

Instead, create an instance of a concrete subclass that provides the missing behavior.

### Subclasses Must Provide Abstract Members

If a base class declares an abstract member, each concrete subclass must implement it:

```typescript
abstract class Formatter {
  abstract format(value: string): string;
}

class UppercaseFormatter extends Formatter {
  format(value: string): string {
    return value.toUpperCase();
  }
}
```

This makes the required behavior explicit in the class hierarchy.

## Classes and Object Identity

Classes are a good fit when individual instances have identity and may change over time:

```typescript
class Session {
  userId: string;
  active: boolean = true;

  constructor(userId: string) {
    this.userId = userId;
  }

  close(): void {
    this.active = false;
  }
}
```

If one part of the program closes a session, another part observing the same instance should see the updated state. This kind of shared object identity is one reason to choose a class.

## Classes and Other Language Features

Classes interact naturally with other ArkTS features:

- methods add behavior to a class
- properties model stored state
- constructors initialize new instances
- inheritance lets one class extend another
- interfaces describe contracts that classes can implement

Those topics are covered in more detail in `methods.md`, `properties.md`, `initialization.md`, `inheritance.md`, and `interfaces.md`.

### Classes and Interfaces

Classes can implement interfaces to make a public contract explicit:

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

In ArkTS, the `implements` clause accepts interfaces, not classes. If two classes should share implementation, use inheritance. If several types should promise the same API, use an interface.

Because ArkTS does not support structural typing, two unrelated classes are not interchangeable just because they expose similar public members.

## When to Use a Class

Use a class when:

- several fields belong together as one concept
- behavior naturally belongs to that data
- instances have identity and may be passed around as objects
- a fixed, explicit object layout is valuable

For example, these are strong class candidates:

- a `User` with profile data and behavior
- a `Task` with completion state
- a `Connection` with open/close logic

If the problem is only a loose group of values, another tool may be better:

- use an array for ordered collections
- use a map for key-value data
- use an enum for a closed set of named choices
- use an interface when you only need a contract

## Design Guidelines for Classes

Good classes usually have:

- one clear responsibility
- field names that describe stable state
- methods that belong naturally to that state
- a constructor that creates valid instances
- a small public surface

If a class becomes a grab bag of unrelated utilities, split the responsibilities rather than growing the class indefinitely.

## ArkTS Restrictions That Affect Classes

ArkTS places stricter rules on classes than TypeScript and JavaScript:

- fields must be declared in the class body
- `#private` identifiers are not supported; use `private`
- object layout cannot change at runtime
- class literals are not supported
- classes cannot be treated as ordinary objects for dynamic manipulation
- constructor parameter properties are not supported
- prototype reassignment is not supported
- reassigning object methods is not supported
- `new.target` is not supported

### Declare Fields Explicitly

Do not declare fields only through constructor shorthand. ArkTS expects them in the class body:

```typescript
class Product {
  name: string;
  price: number;

  constructor(name: string, price: number) {
    this.name = name;
    this.price = price;
  }
}
```

This makes the full instance layout visible in one place.

### Use `private`, Not `#private`

Use ArkTS visibility modifiers instead of JavaScript private identifiers:

```typescript
class Wallet {
  private amount: number = 0;

  add(value: number): void {
    this.amount += value;
  }
}
```

### Implement Interfaces, Not Classes

If a class needs to promise a shared API, implement an interface:

```typescript
interface Resettable {
  reset(): void;
}

class EditorBuffer implements Resettable {
  reset(): void {
    console.info('reset');
  }
}
```

Avoid TypeScript-style patterns such as:

```typescript
// class BaseContract { reset(): void {} }
// class EditorBuffer implements BaseContract {}
```

In ArkTS, `implements` is for interfaces only.

### Do Not Add Members Dynamically

JavaScript often treats objects as open-ended containers, but ArkTS does not:

```typescript
class Settings {
  theme: string = 'light';
}

let settings: Settings = new Settings();
settings.theme = 'dark';
```

Do not teach patterns like adding new fields after creation:

```typescript
// Avoid JavaScript-style patterns such as:
// (settings as any).language = 'en-US';
```

If a field belongs to the type, declare it in the class.

### Do Not Reassign Methods or Prototypes

Methods should be defined in the class body and left there:

```typescript
class Greeter {
  greet(): void {
    console.info('Hello');
  }
}
```

Avoid JavaScript-style prototype mutation and method replacement:

```typescript
// Avoid patterns such as:
// Greeter.prototype.greet = function() {};
// greeter.greet = otherFunction;
```

ArkTS relies on stable structure and conventional class semantics instead.

### Do Not Use Classes as General-Purpose Objects

A class declaration in ArkTS defines a type for instances. It is not meant to be used as a general-purpose object value for dynamic manipulation or object-style metaprogramming.

Prefer ordinary functions, interfaces, or explicit helper objects for those use cases. Use classes when you are modeling instances with declared fields, methods, and initialization rules.

These restrictions are not incidental. They reinforce one of the language's core goals: making object structure explicit, readable, and efficient.
