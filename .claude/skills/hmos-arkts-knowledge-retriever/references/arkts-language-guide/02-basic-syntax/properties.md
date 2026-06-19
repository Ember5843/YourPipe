# Properties

Represent the stored state of a class with typed fields.

In this guide, a property usually means a named field declared inside a class. Properties define what data an instance holds, what defaults it starts with, and which values other code may read or update. They are one of the clearest parts of the ArkTS object model because the available properties are declared explicitly in the class body.

Properties are more than syntax. They are where a type communicates its stable state: a `User` has a `name`, a `Task` has a `completed` flag, and a `Connection` has a `host` and `port`. Good property design makes objects easier to initialize, reason about, and use safely.

## Stored Properties

A stored property keeps a value as part of an instance:

```typescript
class LayoutBox {
  width: number = 0;
  height: number = 0;
}
```

Each new instance gets its own `width` and `height` values:

```typescript
let first: LayoutBox = new LayoutBox();
let second: LayoutBox = new LayoutBox();

first.width = 10;
console.info(second.width); // 0
```

This is what makes object instances useful: each one carries its own state.

## Reading and Writing Properties

Use dot syntax to access a property:

```typescript
let box: LayoutBox = new LayoutBox();
box.width = 10;
box.height = 5;

console.info(box.width * box.height); // 50
```

Dot syntax works because the class definition already tells ArkTS which properties exist. This is one of the reasons ArkTS code is easier to reason about than dynamic object code: member names are known ahead of time.

### Updating Object State

Property assignment is the standard way to update object state:

```typescript
class DownloadTask {
  progress: number = 0;
  completed: boolean = false;
}

let task: DownloadTask = new DownloadTask();
task.progress = 50;
task.completed = task.progress === 100;
```

If state changes need validation or side effects, move the update behind a method instead of exposing raw writes everywhere.

## Computed Properties

Not every useful property needs its own stored value. A computed property derives its value from other fields through a getter:

```typescript
class LayoutBox {
  width: number = 0;
  height: number = 0;

  get area(): number {
    return this.width * this.height;
  }
}

let rectangle: LayoutBox = new LayoutBox();
rectangle.width = 10;
rectangle.height = 5;
console.info(rectangle.area);
```

`area` behaves like a property at the call site, but its value is computed from `width` and `height` every time it is read.

### Computed Properties with Setters

Use a setter when writing the property should update other stored fields in a controlled way:

```typescript
class Temperature {
  private celsiusValue: number = 0;

  get celsius(): number {
    return this.celsiusValue;
  }

  set celsius(value: number) {
    this.celsiusValue = value;
  }

  get fahrenheit(): number {
    return this.celsiusValue * 9 / 5 + 32;
  }

  set fahrenheit(value: number) {
    this.celsiusValue = (value - 32) * 5 / 9;
  }
}
```

This pattern is useful when:

- one public property is derived from another
- writes must preserve an invariant
- the class should expose a simple API while keeping storage details private

If a getter and setter only expose a field with no validation, conversion, or derived behavior, a normal public field is often clearer.

## Default Values

Provide defaults when a sensible initial value exists:

```typescript
class Settings {
  theme: string = 'light';
  fontSize: number = 14;
  showLineNumbers: boolean = true;
}
```

Defaults make instances usable immediately and reduce constructor boilerplate. They also document the normal starting state of the type.

Use default values when:

- a property has a conventional initial state
- most instances start the same way
- the property should always be present

### Defaults and Constructors Together

Defaults and constructors often work together well:

```typescript
class Profile {
  nickname: string | null = null;
  active: boolean = true;
  username: string;

  constructor(username: string) {
    this.username = username;
  }
}
```

Here, the constructor handles the required field, while the class body supplies the normal defaults for the rest.

## Read-Only Properties

Use `readonly` when a property should not change after initialization:

```typescript
class Article {
  readonly id: string;
  title: string;

  constructor(id: string, title: string) {
    this.id = id;
    this.title = title;
  }
}
```

`readonly` documents intent and prevents accidental reassignment. It is especially useful for identifiers, creation-time metadata, and values that define the identity of an instance.

```typescript
class Session {
  readonly userId: string;
  active: boolean = true;

  constructor(userId: string) {
    this.userId = userId;
  }
}
```

The `active` flag may change, but `userId` should not.

### Read-Only Computed Properties

A computed property that only has a getter is read-only:

```typescript
class UserProfile {
  firstName: string;
  lastName: string;

  constructor(firstName: string, lastName: string) {
    this.firstName = firstName;
    this.lastName = lastName;
  }

  get fullName(): string {
    return `${this.firstName} ${this.lastName}`;
  }
}
```

This is different from `readonly`:

- `readonly` protects a stored value after initialization
- a getter-only property does not store the derived value at all

Use a getter-only property when the value is always derived from other state and should not be assigned independently.

## Optional and Nullable State

ArkTS guide examples should model absence explicitly. For class state, a common pattern is a nullable property:

```typescript
class Profile {
  nickname: string | null = null;
}
```

Before using the value, check whether it is `null`:

```typescript
let profile: Profile = new Profile();
if (profile.nickname !== null) {
  console.info(profile.nickname.toUpperCase());
}
```

This is clearer than trying to remove properties dynamically or pretending a field may or may not exist.

### Distinguishing Empty and Missing Values

Sometimes an empty string and a missing value mean different things:

```typescript
function displayNickname(profile: Profile): string {
  if (profile.nickname === null) {
    return 'No nickname';
  }
  if (profile.nickname.length === 0) {
    return 'Empty nickname';
  }
  return profile.nickname;
}
```

Explicit nullable modeling makes these cases visible in code.

### Optional Interface Input vs. Class State

Optional properties and nullable fields solve different problems.

For input objects and lightweight contracts, an interface may use `?` to mean that the caller can omit a value:

```typescript
interface DisplayOptions {
  title: string;
  subtitle?: string;
}
```

For class state, prefer fields that are always declared and explicitly initialized. If a value may be unavailable for part of the object's lifetime, use `null`, a default value, or another state field instead of leaving the shape ambiguous.

## Public, Private, and Protected Properties

Properties can be controlled with access modifiers:

```typescript
class Wallet {
  public owner: string;
  private balance: number = 0;

  constructor(owner: string) {
    this.owner = owner;
  }
}
```

Use access control to separate public state from internal implementation details:

- `public` members are part of the external API
- `private` members are only for the class itself
- `protected` members are available to the class and subclasses

### Prefer Private State When Direct Writes Are Dangerous

```typescript
class ScoreBoard {
  private score: number = 0;

  public add(points: number): void {
    if (points > 0) {
      this.score += points;
    }
  }

  public current(): number {
    return this.score;
  }
}
```

This keeps the object in control of its own invariants.

## Static Properties

Use `static` when a property belongs to the class itself rather than to each instance:

```typescript
class AppInfo {
  static appName: string = 'ArkTS Guide';
}

console.info(AppInfo.appName);
```

Static properties are often used for:

- constants tied to a type
- shared metadata
- default configuration values

```typescript
class Limits {
  static maxRetries: number = 3;
}
```

Static properties are accessed on the class, not on an instance.

## Property Initialization Patterns

Different properties become available at different times:

- some are initialized directly in the class body
- some are assigned in the constructor
- some start as `null` and become available later

For example:

```typescript
class DocumentState {
  readonly id: string;
  title: string;
  published: boolean = false;
  publishedAt: string | null = null;

  constructor(id: string, title: string) {
    this.id = id;
    this.title = title;
  }
}
```

This pattern makes the lifecycle of each property visible:

- `id` is fixed at creation time
- `title` is required but editable
- `published` starts from a default
- `publishedAt` may be absent for a while

## Property Design Guidelines

Prefer property definitions that are:

- explicit in type
- initialized when possible
- limited in visibility
- stable across the lifetime of the object
- named after durable state rather than transient implementation details

Good properties usually describe what an object *has*, not what an operation *does*. If a member performs work or validation, it often belongs in a method instead.

## Properties and Methods

Properties and methods often work together. Properties store state; methods interpret or update that state:

```typescript
class LightSwitch {
  private on: boolean = false;

  turnOn(): void {
    this.on = true;
  }

  turnOff(): void {
    this.on = false;
  }

  isOn(): boolean {
    return this.on;
  }
}
```

This is often better than exposing every field for arbitrary external writes.

For methods that operate on properties, see `methods.md`.

## ArkTS Restrictions That Affect Properties

ArkTS does not allow code to add or remove properties from an instance at runtime. The class body defines the full object layout:

```typescript
class Device {
  name: string = '';
}

let device: Device = new Device();
device.name = 'Phone';
```

This means:

- `delete` is not supported
- runtime property injection is not supported
- indexed signatures are not supported for class-style property modeling
- dynamic field access by arbitrary index is not supported
- property names should be regular declared identifiers
- constructor parameter properties are not supported
- definite assignment assertions should not be a normal property initialization strategy

### Declare Properties Explicitly

If a property may exist, declare it in the class:

```typescript
class Device {
  name: string = '';
  language: string | null = null;
}
```

Do not teach patterns like:

```typescript
// Avoid JavaScript-style patterns such as:
// (device as any).language = 'en-US';
// delete device.name;
```

### Prefer Explicit Initialization Over `!`

ArkTS code is clearest when a property's first valid value is visible at declaration time or in the constructor:

```typescript
class Job {
  id: string;
  result: string | null = null;

  constructor(id: string) {
    this.id = id;
  }
}
```

Avoid teaching `!` as the normal way to silence initialization checks:

```typescript
// Avoid patterns such as:
// class Job {
//   result!: string;
// }
```

If a value is not available yet, model that state directly with `null`, a default value, or a constructor requirement.

### Do Not Use Index-Based Field Access for Class State

Class state should be modeled with named fields, not dynamic property lookup:

```typescript
class Point {
  x: number = 0;
  y: number = 0;
}

let point: Point = new Point();
console.info(point.x + point.y);
```

This is clearer and matches ArkTS's static object model.

### Use Accessors for Derived or Controlled State

ArkTS can expose property-style APIs with `get` and `set`, but they should serve a real design purpose:

- expose derived values such as `area` or `fullName`
- translate between public units and private storage
- validate or normalize assignments

Do not use accessors just to wrap a field without changing behavior.

### Model Absence Explicitly

If a value may be unavailable, use one of these patterns instead of removing the property:

- a default value
- `null`
- an optional property on an interface input object
- a separate boolean state field
- a method that validates access

For constructor-based property setup, see `initialization.md`. For visibility and member ownership inside classes, see `classes.md`.
