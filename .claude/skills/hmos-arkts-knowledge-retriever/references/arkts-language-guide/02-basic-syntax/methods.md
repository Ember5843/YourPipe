# Methods

Attach behavior to a class with functions defined inside the class body.

A method is a function that belongs to a class. Methods typically read or update properties, enforce invariants, and give an object behavior that matches its role in the program. If properties describe what an object *has*, methods describe what an object *can do*.

In ArkTS, methods are also part of a class's explicit structure. They should be defined in the class body, called through the instance or type, and used to keep state-related logic close to the data it affects. This makes object behavior easier to discover and harder to misuse.

Methods are still functions, so they can take parameters, return values, and call other methods. The difference is that a method is attached to a type and participates in that type's explicit API.

## Instance Methods

Define an instance method directly in the class body:

```typescript
class TapCounter {
  value: number = 0;

  increment(): void {
    this.value += 1;
  }
}
```

Call the method on an instance:

```typescript
let counter: TapCounter = new TapCounter();
counter.increment();
console.info(counter.value); // 1
```

Instance methods operate on the state of a specific object. That is why they are called on an instance rather than on the class itself.

Instance methods also have direct access to the instance's fields and to other instance methods of the same class. That makes them the natural place for behavior that depends on object state.

## Methods with Parameters

Methods accept parameters just like ordinary functions:

```typescript
class Calculator {
  add(x: number, y: number): number {
    return x + y;
  }
}
```

Parameter types should be clear, especially when the method is part of the public API of the class.

Methods often become easier to understand when parameters describe intent rather than mechanics:

```typescript
class Timer {
  setDuration(seconds: number): void {
    console.info(`Duration set to ${seconds}`);
  }
}
```

Methods can also use the same parameter features as ordinary functions.

### Optional and Default Parameters

Use optional or default parameters when the method naturally supports more than one common calling style:

```typescript
class TextPrinter {
  printLine(text: string, prefix: string = '[INFO]'): void {
    console.info(`${prefix} ${text}`);
  }
}
```

Default parameters often keep the method simpler than creating several near-identical variants.

### Rest Parameters

Use rest parameters when the method needs to accept a variable number of values:

```typescript
class SumBuilder {
  addAll(...values: number[]): number {
    let total: number = 0;
    for (let value of values) {
      total += value;
    }
    return total;
  }
}
```

This keeps the API explicit while still allowing flexible calls.

## Methods That Return Values

Many methods compute and return a result:

```typescript
class MeasureBox {
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
```

Methods that return values often answer questions about the current object:

- `area()` computes a measurement
- `isActive()` reports state
- `currentBalance()` exposes a safe view of internal data

Explicit return types improve readability in guide examples and help keep method contracts stable.

## Using `this`

Inside an instance method, use `this` to refer to the current object:

```typescript
class Greeter {
  prefix: string = 'Hello';

  greet(name: string): string {
    return `${this.prefix}, ${name}`;
  }
}
```

Without `this`, the code could refer to a different name in the surrounding scope if one exists.

### Why `this` Matters

Methods usually need access to the object's own properties:

```typescript
class Light {
  enabled: boolean = false;

  turnOn(): void {
    this.enabled = true;
  }

  turnOff(): void {
    this.enabled = false;
  }
}
```

Here, `this.enabled` clearly means "the `enabled` field on the current `Light` instance".

### Disambiguating Parameter Names

`this` is also useful when a parameter name and a property name are the same:

```typescript
class User {
  name: string = '';

  rename(name: string): void {
    this.name = name;
  }
}
```

The left side refers to the property, and the right side refers to the parameter.

## Updating Object State

Methods often exist to enforce safe updates to properties:

```typescript
class BankAccount {
  private balance: number = 0;

  deposit(amount: number): void {
    if (amount > 0) {
      this.balance += amount;
    }
  }

  currentBalance(): number {
    return this.balance;
  }
}
```

This pattern keeps validation inside the class instead of scattering it across unrelated code.

### Methods as the Safe Way to Change State

When direct writes could break invariants, a method is usually the better API:

```typescript
class ProgressTracker {
  private progress: number = 0;

  updateProgress(value: number): void {
    if (value < 0) {
      this.progress = 0;
      return;
    }
    if (value > 100) {
      this.progress = 100;
      return;
    }
    this.progress = value;
  }

  currentProgress(): number {
    return this.progress;
  }
}
```

The method protects the object from invalid state.

## Methods as Part of a Class API

Because methods live on the class, they should express stable, intentional behavior. A good method usually does one of these jobs:

- updates object state safely
- answers a question about the current object
- coordinates several internal steps
- exposes behavior that conceptually belongs to the type

That is why methods are usually clearer than scattered helper logic around the class.

## Methods Calling Other Methods

Methods often collaborate inside the same class:

```typescript
class Order {
  subtotal: number;

  constructor(subtotal: number) {
    this.subtotal = subtotal;
  }

  tax(): number {
    return this.subtotal * 0.1;
  }

  total(): number {
    return this.subtotal + this.tax();
  }
}
```

This keeps related logic grouped together and avoids repeating calculations in multiple places.

When a method builds on another method, the class API stays easier to maintain because shared logic remains in one place.

## Static Methods

Static methods belong to the class rather than to an instance:

```typescript
class Temperature {
  static fromCelsius(celsius: number): number {
    return celsius * 9 / 5 + 32;
  }
}

console.info(Temperature.fromCelsius(25)); // 77
```

Use a static method when the behavior conceptually belongs to the type as a whole instead of one particular instance.

Static methods are useful for:

- conversion helpers
- named factory-style creation
- utility operations tied to a type

```typescript
class IdGenerator {
  static next(prefix: string, value: number): string {
    return `${prefix}-${value}`;
  }
}
```

Call a static method on the class itself, not on an object instance.

In ArkTS, static methods should not rely on `this`. If a static method needs another static member, prefer the explicit class name:

```typescript
class MathHelper {
  static scale: number = 2;

  static double(value: number): number {
    return value * MathHelper.scale;
  }
}
```

## Methods and Callbacks

Methods can call other functions or accept callback parameters:

```typescript
class Processor {
  apply(values: number[], transform: (value: number) => number): number[] {
    let result: number[] = [];
    for (let value of values) {
      result.push(transform(value));
    }
    return result;
  }
}
```

This is a common way to combine object-oriented structure with functional-style helpers.

Callbacks passed into methods should usually be simple and explicitly typed. That keeps the boundary between the object and external logic easy to follow.

## Local Helper Logic Inside Methods

When a method needs a small helper, use an arrow function variable:

```typescript
class Reporter {
  printTwice(text: string): void {
    let printLine: (value: string) => void = (value: string): void => {
      console.info(value);
    };

    printLine(text);
    printLine(text);
  }
}
```

This works well with ArkTS restrictions on nested function declarations.

Use this pattern for short, local-only helpers. If the helper becomes reusable or important to the public behavior of the class, promote it to a named method.

## Overload-Style Method Design

Methods can be designed to support several calling patterns, but not every such API needs overloads.

In ArkTS guide-style code, prefer these options first:

- union types
- optional parameters
- default parameters
- separate clearly named methods

For example, this kind of method is often clear without overloads:

```typescript
class Greeter {
  greet(name: string, title?: string): string {
    if (title != undefined) {
      return `Hello, ${title} ${name}`;
    }
    return `Hello, ${name}`;
  }
}
```

Use overload-style design only when the supported call shapes are meaningfully different and a single straightforward signature would be harder to understand.

## Read-Only and Query-Style Methods

Not every method changes state. Some methods simply expose derived information:

```typescript
class RoundShape {
  radius: number;

  constructor(radius: number) {
    this.radius = radius;
  }

  diameter(): number {
    return this.radius * 2;
  }
}
```

These query-style methods are useful when:

- the value is derived from other fields
- computing it on demand is clearer than storing it
- you want a named operation rather than direct arithmetic at each call site

## Method Design Guidelines

Prefer methods that are:

- centered on one responsibility
- clearly named after an action or query
- small enough to understand quickly
- close to the state they read or modify
- explicit about parameter and return types

Good method names usually sound like verbs or questions:

- `deposit`
- `reset`
- `rename`
- `isReady`
- `currentBalance`

If a method starts handling several unrelated concerns, split it before the class becomes hard to reason about.

## ArkTS Restrictions That Affect Methods

ArkTS keeps methods more static than JavaScript:

- reassigning object methods at runtime is not supported
- prototype assignment is not supported
- nested function declarations inside methods are not supported
- function expressions are not supported
- using `this` inside stand-alone functions is not supported
- using `this` inside static methods is not supported
- `Function.call` and `Function.apply` are not supported
- `Function.bind` is not supported

### Define Behavior in the Class Body

Declare methods directly in the class:

```typescript
class Logger {
  info(text: string): void {
    console.info(text);
  }
}
```

Do not patch methods in later:

```typescript
// Avoid JavaScript-style patterns such as:
// logger.info = otherFunction;
```

Do not move method definitions onto a type later through prototype updates either. In ArkTS, behavior should be declared where the class is declared.

### Prefer Class-Declared Behavior Over Runtime Patching

JavaScript often treats methods as something that can be replaced or attached later. ArkTS does not.

Prefer patterns like these:

- declare methods directly in the class body
- use inheritance when behavior varies by subtype
- use wrapper functions when behavior needs external coordination

Avoid patterns like these:

- assigning a new function to an existing object's method
- adding methods through `prototype`
- taking a stand-alone function that uses `this` and attaching it to an object later

### Do Not Rely on Function-Style `this`

ArkTS expects `this` to be used in conventional class methods, not in detached stand-alone functions:

```typescript
class Clock {
  ticks: number = 0;

  tick(): void {
    this.ticks++;
  }
}
```

This is better than passing methods around and trying to recover `this` with `bind()`, `call()`, or `apply()`.

If logic genuinely belongs to the instance, keep it as an instance method. If it does not need instance state, make it a static method or a separate helper function that does not depend on `this`.

### Use Arrow Functions for Local Logic

If a method needs local helper behavior, prefer a typed arrow function:

```typescript
class Formatter {
  print(value: string): void {
    let write: (text: string) => void = (text: string): void => {
      console.info(text);
    };

    write(value.trim());
  }
}
```

This preserves a stable class shape and keeps behavior visible where the class is declared.

Arrow functions are also the correct local alternative when JavaScript examples would use a function expression. ArkTS does not support function expressions, so helper logic inside a method should stay in arrow form.

### Do Not Detach `this`-Dependent Methods

In JavaScript and TypeScript, developers sometimes pass an instance method around as if it were an ordinary function and later restore its receiver with `bind`, `call`, or `apply`. That style does not fit ArkTS.

Prefer one of these approaches instead:

- call the method on the instance directly
- wrap the call in an arrow function
- move shared logic into a helper that does not rely on `this`

This keeps method behavior explicit and avoids context-related surprises.

For class declarations, see `classes.md`. For access modifiers and accessors, see `properties.md`. For inherited methods, see `inheritance.md`.
