# Initialization

Give every new instance a valid starting state.

Initialization is the process of preparing a class instance before it is used. In ArkTS, initialization is handled through field initializers and constructors. Because object layout is explicit, every field should be declared clearly and assigned a sensible value before the instance begins normal use.

Initialization is not just "filling in fields". It defines the first legal state of an object. A well-initialized object can be used immediately and safely; a poorly initialized one forces every later method to defend against missing or unclear state.

## Default Property Values

The simplest initialization pattern is to assign default values directly in the class body:

```typescript
class Settings {
  theme: string = 'light';
  fontSize: number = 14;
  autosave: boolean = true;
}
```

Defaults work well when most instances start in the same state. They make the class easier to read because the initial state is visible where the fields are declared.

Use defaults when:

- a field has an obvious conventional value
- most callers should not need to think about the field
- the object should be usable immediately after creation

## Constructors

Use a constructor when values must come from the caller:

```typescript
class Book {
  title: string;
  pageCount: number;

  constructor(title: string, pageCount: number) {
    this.title = title;
    this.pageCount = pageCount;
  }
}
```

The constructor establishes the first valid state of the object. This is where required data is accepted, validated, and assigned.

Constructors are especially appropriate when:

- some fields cannot have meaningful defaults
- invalid input should prevent object creation
- the object must start in a caller-specific state

## Combining Defaults and Parameters

Field defaults and constructor parameters are often used together:

```typescript
class Connection {
  host: string;
  port: number = 8080;
  secure: boolean = false;

  constructor(host: string) {
    this.host = host;
  }
}
```

This is useful when some fields have obvious defaults and others must be provided explicitly.

A common pattern is:

- required identity or configuration comes from constructor parameters
- secondary fields use defaults
- nullable fields represent state that will become available later

```typescript
class UserSession {
  readonly userId: string;
  active: boolean = true;
  nickname: string | null = null;

  constructor(userId: string) {
    this.userId = userId;
  }
}
```

## Initialization Order

For a class without inheritance, a good mental model is:

1. declare fields
2. apply field defaults
3. run the constructor
4. finish with a valid, usable object

To keep initialization easy to reason about:

- declare all fields near the top of the class
- assign required fields in the constructor
- keep validation close to assignment
- avoid spreading essential setup across unrelated methods

The goal is that a reader can understand an object's starting state without hunting through the file.

### Initialization Order in Inheritance

In a derived class, the order is more specific:

1. base-class field defaults are applied
2. the base-class constructor runs
3. derived-class field defaults are applied
4. the derived-class constructor runs

This means a base-class constructor sees the base-class state, not the final derived-class state:

```typescript
class BaseMessage {
  label: string = 'base';

  constructor() {
    console.info(this.label);
  }
}

class DetailedMessage extends BaseMessage {
  label: string = 'derived';
}

let message: DetailedMessage = new DetailedMessage(); // prints 'base'
```

When a base constructor runs, derived fields have not finished initializing yet. Avoid designs that depend on subclass field values already being available during base-class construction.

## Required, Defaulted, and Deferred State

Different fields belong to different categories:

- required fields must be assigned during construction
- defaulted fields already have a normal initial value
- deferred fields should be modeled explicitly, usually with `null`

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

This pattern makes the lifecycle of each field visible:

- `id` is fixed at creation time
- `title` is required but editable
- `published` starts from a default
- `publishedAt` is absent until publication happens

## Read-Only Properties and Initialization

`readonly` properties are often set during initialization:

```typescript
class Session {
  readonly id: string;
  userName: string;

  constructor(id: string, userName: string) {
    this.id = id;
    this.userName = userName;
  }
}
```

After the instance is created, `id` should not be reassigned. This makes `readonly` a natural fit for identifiers and other creation-time facts.

In ArkTS, `readonly` works best when the value is established in one of two explicit places:

- at the field declaration
- in the constructor

```typescript
class BuildInfo {
  readonly version: string = '1.0.0';
  readonly buildId: string;

  constructor(buildId: string) {
    this.buildId = buildId;
  }
}
```

This keeps immutable state visible at the point where the instance is created.

## Nullable Properties During Initialization

When a property may genuinely be absent, model that case explicitly:

```typescript
class Profile {
  nickname: string | null = null;
  age: number | null = null;
}
```

This is safer than leaving the object in an unclear partial state.

Check nullable fields explicitly before using them:

```typescript
function printNickname(profile: Profile): void {
  if (profile.nickname === null) {
    console.info('No nickname');
    return;
  }

  console.info(profile.nickname.toUpperCase());
}
```

## Constructor Validation

Constructors may validate inputs before completing initialization:

```typescript
class ValidatedPercentage {
  value: number;

  constructor(value: number) {
    if (value < 0 || value > 100) {
      throw new Error('Percentage must be between 0 and 100');
    }
    this.value = value;
  }
}
```

This keeps invalid objects from being created in the first place.

Validation is often better in the constructor than in later methods when:

- the value is required for the object to make sense
- every instance must obey the same rule
- later code should not need to defend against an invalid object

## Initialization in Derived Classes

Derived classes initialize both the base-class part and the derived-class part of the instance:

```typescript
class Employee {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class Manager extends Employee {
  teamSize: number;

  constructor(name: string, teamSize: number) {
    super(name);
    this.teamSize = teamSize;
  }
}
```

The `super(...)` call must happen before the derived class uses `this`.

### Extending Initialization Carefully

The base class should finish its part of initialization before the subclass starts using inherited state:

```typescript
class FileResource {
  path: string;

  constructor(path: string) {
    this.path = path;
  }
}

class CachedFileResource extends FileResource {
  cached: boolean = false;

  constructor(path: string) {
    super(path);
  }
}
```

Keep base-class initialization simple and predictable so subclasses remain easy to reason about.

## Factory-Style Alternatives

Sometimes a normal constructor is not the clearest API. A static factory method can make intent explicit:

```typescript
class RgbColor {
  red: number;
  green: number;
  blue: number;

  constructor(red: number, green: number, blue: number) {
    this.red = red;
    this.green = green;
    this.blue = blue;
  }

  static black(): RgbColor {
    return new RgbColor(0, 0, 0);
  }
}
```

This pattern is helpful when:

- several named construction paths exist
- a constructor call would be ambiguous
- the creation intent deserves a meaningful name

Another example:

```typescript
class RetryPolicy {
  maxRetries: number;
  delayMs: number;

  constructor(maxRetries: number, delayMs: number) {
    this.maxRetries = maxRetries;
    this.delayMs = delayMs;
  }

  static defaultPolicy(): RetryPolicy {
    return new RetryPolicy(3, 1000);
  }
}
```

## Initialization Design Guidelines

Prefer initialization logic that is:

- explicit about which fields are required
- short enough to inspect quickly
- close to the fields it initializes
- validated where necessary
- free of hidden setup steps

If a constructor becomes too long, the class may be taking on too many responsibilities or may need helper methods that operate after initialization, not during it.

## ArkTS Restrictions That Affect Initialization

ArkTS removes several TypeScript conveniences in order to keep initialization explicit:

- constructor parameter properties are not supported
- definite assignment assertions are not supported
- class fields must be declared in the class body
- object literal initialization is only supported in limited cases

### Declare Fields in the Class Body

Instead of TypeScript-style constructor shorthand, declare each field explicitly and assign it in the constructor:

```typescript
// Avoid TypeScript-style constructor parameter properties such as:
// class Order {
//   constructor(public id: string, private total: number) {}
// }

class Order {
  id: string;
  total: number;

  constructor(id: string, total: number) {
    this.id = id;
    this.total = total;
  }
}
```

This style is longer, but it makes the full object layout visible in one place and aligns with ArkTS's static design.

The same rule applies to modifiers such as `public`, `private`, `protected`, and `readonly`: use them on the field declaration in the class body, not on constructor parameters.

### Do Not Use Definite Assignment Assertions

Do not skip initialization with `!`:

```typescript
// Avoid TypeScript-style patterns such as:
// class User {
//   name!: string;
// }
```

Use one of these explicit alternatives instead:

- assign a default value
- initialize the field in the constructor
- model deferred state with `null`

```typescript
class User {
  name: string;
  nickname: string | null = null;

  constructor(name: string) {
    this.name = name;
  }
}
```

These rules reinforce one of ArkTS's core ideas: an object's structure and starting state should be visible and trustworthy from the moment it is created.

### Use Object Literals Only in Supported Cases

ArkTS allows some object literal initialization, but it is a restricted feature rather than the normal way to create class instances.

When a class has initialization behavior, prefer `new` and the constructor:

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

Typed object literals are appropriate only when the target class or interface is explicit and does not rely on restricted features:

```typescript
class Point {
  x: number = 0;
  y: number = 0;
}

let point: Point = { x: 5, y: 10 };
```

Object literal initialization is not appropriate for several common ArkTS cases:

- classes with methods
- classes with custom constructors that take parameters
- classes with `readonly` fields
- values typed as `Object`, `object`, or `any`

For example, this should be written with `new` instead of a literal:

```typescript
class Account {
  readonly id: string;
  active: boolean = true;

  constructor(id: string) {
    this.id = id;
  }
}

let account: Account = new Account('A-100');
```

This rule keeps initialization behavior tied to the declared type instead of treating a class as a loose object shape.

For stored fields and property design, see `properties.md`. For class structure more broadly, see `classes.md`.
