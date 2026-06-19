# Inheritance

Create a new class from an existing class by using `extends`.

Inheritance allows one class to build on another class. A derived class receives the accessible properties and methods of the base class, can introduce new members of its own, and can replace behavior by overriding methods. This is useful when several classes share a meaningful common model and should expose a compatible API.

In ArkTS, inheritance should be intentional rather than convenient. It is not a general substitute for "these two classes happen to look similar". Because ArkTS does not rely on structural typing, a class hierarchy should represent a real conceptual relationship.

## Defining a Base Class

Start with a class that describes shared state or shared behavior:

```typescript
class Animal {
  name: string;

  constructor(name: string) {
    this.name = name;
  }

  speak(): string {
    return `${this.name} makes a sound`;
  }
}
```

This class now acts as a common parent for more specific animal types.

A base class should capture behavior that is genuinely shared. If the base type is too vague or too broad, derived classes quickly become confusing.

## Creating a Derived Class

Use `extends` to derive from a base class:

```typescript
class Dog extends Animal {
  speak(): string {
    return `${this.name} barks`;
  }
}
```

The derived class inherits `name` and replaces `speak()` with a more specific implementation.

A derived class may also inherit methods and fields without redefining them:

```typescript
let dog: Dog = new Dog('Buddy');
console.info(dog.name);
console.info(dog.speak());
```

## Calling `super`

If a derived class defines a constructor, it must call `super(...)` before using `this`:

```typescript
class GuideDog extends Dog {
  role: string;

  constructor(name: string, role: string) {
    super(name);
    this.role = role;
  }
}
```

The `super(...)` call initializes the base-class part of the object. After that, the derived class can finish its own initialization.

### Why `super` Comes First

The base class owns part of the object state. Its constructor must run before the derived class can safely rely on inherited members:

```typescript
class Vehicle {
  label: string;

  constructor(label: string) {
    this.label = label;
  }
}

class Car extends Vehicle {
  wheels: number;

  constructor(label: string, wheels: number) {
    super(label);
    this.wheels = wheels;
  }
}
```

This ordering keeps initialization rules explicit and predictable.

## Adding New Members

A derived class can add new properties and methods:

```typescript
class Bird extends Animal {
  canFly: boolean;

  constructor(name: string, canFly: boolean) {
    super(name);
    this.canFly = canFly;
  }

  flyDescription(): string {
    if (this.canFly) {
      return `${this.name} can fly`;
    }
    return `${this.name} cannot fly`;
  }
}
```

Inheritance is most useful when the derived class truly is a specialized version of the base class.

The base class provides the common vocabulary; the subclass adds details that only it needs.

## Overriding Methods

A derived class may replace inherited behavior:

```typescript
class Cat extends Animal {
  speak(): string {
    return `${this.name} meows`;
  }
}
```

When overriding a method, preserve the basic meaning of the base-class API so the class hierarchy remains understandable.

For example, if `speak()` is meant to return a human-readable sound description, each subclass should continue doing that rather than changing the method into something unrelated.

### Reusing Base Behavior with `super`

An override can also build on the base implementation:

```typescript
class LoudDog extends Dog {
  speak(): string {
    return super.speak().toUpperCase();
  }
}
```

Use this when the derived behavior is a refinement of the base behavior rather than a total replacement.

### Derived Instances Through Base References

Derived objects are commonly used through variables whose type is the base class:

```typescript
class Notification {
  show(): string {
    return 'notification';
  }
}

class ErrorNotification extends Notification {
  show(): string {
    return 'error notification';
  }
}

let message: Notification = new ErrorNotification();
console.info(message.show());
```

This works because a derived class is a subtype of its base class.

It also explains why an override must preserve the meaning of the base API. If code only knows that `message` is a `Notification`, calling `show()` should still behave like a valid notification display operation.

## Inherited State and Behavior

A subclass automatically inherits accessible members from the base class:

```typescript
class Employee {
  name: string;

  constructor(name: string) {
    this.name = name;
  }

  describe(): string {
    return `Employee: ${this.name}`;
  }
}

class Manager extends Employee {
  teamSize: number;

  constructor(name: string, teamSize: number) {
    super(name);
    this.teamSize = teamSize;
  }
}

let manager: Manager = new Manager('Grace', 5);
console.info(manager.describe());
```

The subclass can use inherited members directly as long as their visibility allows it.

## Initialization Order in a Hierarchy

When a derived object is created, initialization proceeds in a fixed order:

1. base-class field defaults are applied
2. the base-class constructor runs
3. derived-class field defaults are applied
4. the derived-class constructor runs

For example:

```typescript
class Base {
  label: string = 'base';

  constructor() {
    console.info(this.label);
  }
}

class Derived extends Base {
  label: string = 'derived';
}

let value: Derived = new Derived(); // prints "base"
```

During the base constructor, the derived part of the object has not finished its own field initialization yet.

Keep this rule in mind when designing a base class:

- avoid relying on subclass field values inside the base constructor
- keep base initialization simple and predictable
- prefer initialization logic that depends only on base-class state

## Protected Members

Use `protected` when a base class wants to share internal implementation details with subclasses:

```typescript
class Vehicle {
  protected speed: number = 0;

  protected accelerate(step: number): void {
    this.speed += step;
  }
}

class Car extends Vehicle {
  increaseSpeed(): void {
    this.accelerate(10);
  }
}
```

Outside code cannot access `protected` members directly. They are intended for the hierarchy itself, not for general callers.

### When to Choose `protected`

Use `protected` only when subclasses genuinely need access to the member. If outside code should not see it and subclasses do not need it either, keep it `private`.

Unlike `protected`, `private` members are not available in subclasses. Choose `protected` only for members that are intentionally part of the subclassing surface.

## ArkTS Inheritance Boundaries

ArkTS keeps inheritance explicit and class-based.

### Single Inheritance

A class can extend one base class:

```typescript
class Device {
  id: string = '';
}

class Sensor extends Device {
  unit: string = '';
}
```

If a type needs to reuse behavior from several sources, prefer interfaces for shared contracts and composition for shared implementation.

### Classes Extend Classes

In ArkTS, class inheritance uses `extends`, and interfaces extend only interfaces. An interface does not inherit from a class.

```typescript
interface Identified {
  id: string;
}

interface NamedDevice extends Identified {
  name: string;
}
```

Use class inheritance when you need shared implementation or stored state. Use interfaces when you need a shared public contract.

### No JavaScript-Style Prototype Inheritance

ArkTS does not use JavaScript's runtime prototype inheritance model. In particular, patterns based on prototype reassignment or `new.target`-driven inheritance behavior are not part of normal ArkTS class design.

Write inheritance through explicit class declarations and `extends`. Avoid JavaScript patterns that mutate inheritance relationships at runtime.

## When Inheritance Helps

Inheritance is a good fit when:

- several classes share common state or behavior
- the relationship is truly "is a kind of"
- the base class defines a meaningful common API
- subclasses should be usable anywhere the base class is expected

Examples that often make sense:

- `Dog` extends `Animal`
- `Manager` extends `Employee`
- `CachedFileResource` extends `FileResource`

Do not use inheritance only to avoid writing duplicate lines if the types are not conceptually related.

## When Inheritance Hurts

Inheritance is usually a poor fit when:

- the relationship is really "has a" rather than "is a"
- the base class exists only to share a few utility methods
- subclasses need to ignore or fight the base behavior
- the hierarchy becomes deep and hard to follow

For example, if a `ReportPrinter` needs a `Logger`, that is usually composition, not inheritance. The class should contain a logger field instead of extending `Logger`.

## Inheritance and Interfaces

Classes inherit from classes, while interfaces define contracts:

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

Use class inheritance for shared implementation and shared stored state. Use interfaces for shared requirements.

For abstract base classes, see `classes.md`. For migration rules that differ from TypeScript or JavaScript, see `../09-Migration-Guide/01-TypeScript-to-ArkTS/typescript-to-arkts-migration-guide.md`.

### Combining Both

A class can both extend a class and implement interfaces:

```typescript
interface Named {
  displayName(): string;
}

class Person {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class EmployeeRecord extends Person implements Named {
  displayName(): string {
    return this.name;
  }
}
```

This is often a good way to separate shared implementation from shared API promises.

## Designing Base Classes Carefully

A base class should:

- have a clear responsibility
- expose behavior that is meaningful for all subclasses
- avoid forcing unrelated state onto subclasses
- remain small enough to understand easily

If every subclass overrides most of the base class, the base class may not be a good abstraction.
