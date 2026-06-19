# Collection Types

Organize related values with arrays, sets, and maps.

Most real programs do not work with isolated values. They work with lists of users, sets of active features, maps of configuration entries, queues of tasks, and tables of computed results. Collection types let you represent those grouped values directly, instead of scattering related variables throughout the code.

ArkTS keeps collections strongly typed. That means the compiler knows which kind of values each collection may contain, which operations are valid, and where missing values must be handled explicitly. This design is especially important in ArkTS because many JavaScript-style "object as dictionary" patterns are restricted or unsupported.

This chapter introduces the three core collection shapes you will use most often:

- arrays for ordered sequences
- sets for unique values
- maps for key-value associations

## Mutability of Collections

When a collection is stored in a variable declared with `let`, the variable can be reassigned, and the collection's contents can usually be updated as well:

```typescript
let numbers: number[] = [1, 2, 3];
numbers.push(4);
console.info(numbers.length); // 4
```

When a collection reference is stored in a `const`, the variable itself cannot be reassigned:

```typescript
const names: string[] = ['Alice', 'Bob'];
console.info(names[0]); // Alice
```

Use the narrowest mutability that fits the task. If a collection should not be replaced, prefer `const`. If it should not be modified either, keep the API around it narrow and avoid unnecessary writes.

## Arrays

An array stores values of the same type in an ordered sequence:

```typescript
let scores: number[] = [95, 88, 76];
console.info(scores[0]); // 95
```

Arrays are the right choice when:

- order matters
- duplicate values are allowed
- indexed access is useful
- values are naturally processed from first to last

ArkTS arrays are typed as `T[]` or `Array<T>`. In this guide, the shorter `T[]` form is preferred:

```typescript
let ids: number[] = [1001, 1002, 1003];
```

## Creating Arrays

The most common way to create an array is with an array literal:

```typescript
let languages: string[] = ['ArkTS', 'TypeScript', 'JavaScript'];
```

Create an empty array by writing the element type explicitly:

```typescript
let tasks: string[] = [];
tasks.push('parse input');
tasks.push('validate state');
```

Build an array step by step when the values are computed:

```typescript
let evenNumbers: number[] = [];
for (let i = 0; i <= 10; i++) {
  if (i % 2 === 0) {
    evenNumbers.push(i);
  }
}
```

You can also derive new arrays from existing data:

```typescript
let base: number[] = [1, 2, 3];
let extended: number[] = base.concat([4, 5]);
console.info(extended); // [1, 2, 3, 4, 5]
```

Prefer these explicit creation styles over JavaScript patterns such as `Array(length)` or manually stretching `length`. In ArkTS, it is better to construct arrays with real elements from the beginning, or start from `[]` and append values as they are produced.

### Avoid Sparse or Dynamically Shaped Arrays

JavaScript arrays can behave like loosely shaped objects, but that is not a good ArkTS model. Prefer dense, explicitly typed arrays:

```typescript
let queue: string[] = ['A', 'B', 'C'];
```

Do not teach patterns that depend on assigning arbitrary non-index properties or treating arrays as general objects.

Avoid examples that rely on:

- empty slots in sparse arrays
- writing `array.length = ...` to reshape the array
- assigning custom properties such as `array.label = 'queue'`
- iterating arrays with `for...in`

## Accessing and Modifying Arrays

Use an index to read or update a specific element:

```typescript
let queue: string[] = ['A', 'B', 'C'];
console.info(queue[1]); // B

queue[1] = 'Updated';
console.info(queue[1]); // Updated
```

Append elements with `push()` and remove the last element with `pop()`:

```typescript
let values: number[] = [10, 20];
values.push(30);

let removed: number | undefined = values.pop();
console.info(removed); // 30
```

You can also add or remove values at the front of an array:

```typescript
let pending: string[] = ['compile', 'test'];
pending.unshift('clean');

let firstStep: string | undefined = pending.shift();
console.info(firstStep); // clean
```

Insert or remove items at a position with `splice()`:

```typescript
let steps: string[] = ['parse', 'emit'];
steps.splice(1, 0, 'check');
console.info(steps.join(' -> ')); // parse -> check -> emit
```

Use `length` when the number of elements matters:

```typescript
let steps: string[] = [];

if (steps.length === 0) {
  console.info('No work to do');
}
```

### Handling Missing Elements

Some array operations may produce `undefined`, so the result type should be handled explicitly:

```typescript
let items: string[] = ['first', 'second'];
let lastItem: string | undefined = items.pop();

if (lastItem !== undefined) {
  console.info(lastItem);
}
```

This is better than assuming the array always contains data.

The same idea applies to search operations such as `find()`:

```typescript
let candidates: number[] = [3, 7, 10, 14];
let firstEven: number | undefined = candidates.find((value: number): boolean => {
  return value % 2 === 0;
});

if (firstEven !== undefined) {
  console.info(firstEven); // 10
}
```

## Iterating Over Arrays

Use `for...of` when you need each value:

```typescript
let fruits: string[] = ['apple', 'banana', 'orange'];
for (let fruit of fruits) {
  console.info(fruit);
}
```

Use an index-based loop when you need both the position and the value:

```typescript
for (let i = 0; i < fruits.length; i++) {
  console.info(`${i}: ${fruits[i]}`);
}
```

Use array methods such as `forEach()` when the operation is simple and side-effect oriented:

```typescript
fruits.forEach((fruit: string): void => {
  console.info(fruit.toUpperCase());
});
```

Choose the style that best matches the task:

- `for...of` for direct value traversal
- indexed `for` loops when positions matter
- `forEach()` for short, local operations

Do not use `for...in` for arrays. It is a poor match for ordered collection traversal and encourages a JavaScript object-property view that ArkTS code should avoid.

## Useful Array Operations

Arrays provide practical helpers for common transformations:

```typescript
let source: number[] = [1, 2, 3, 4];

let doubled: number[] = source.map((value: number): number => {
  return value * 2;
});

let filtered: number[] = source.filter((value: number): boolean => {
  return value % 2 === 0;
});

console.info(doubled);  // [2, 4, 6, 8]
console.info(filtered); // [2, 4]
```

Some other commonly used operations are:

- `join()` to produce text
- `concat()` to combine arrays
- `slice()` to copy part of an array
- `includes()` to test membership
- `indexOf()` to find a position

```typescript
let modules: string[] = ['syntax', 'types', 'generics'];
console.info(modules.includes('types')); // true
console.info(modules.slice(0, 2).join(', ')); // syntax, types
```

Boolean checks across a collection are also common:

```typescript
let results: number[] = [88, 91, 76];
let allPassed: boolean = results.every((value: number): boolean => {
  return value >= 60;
});
let hasExcellent: boolean = results.some((value: number): boolean => {
  return value >= 90;
});

console.info(allPassed);    // true
console.info(hasExcellent); // true
```

When you need to combine many values into one result, use `reduce()`:

```typescript
let expenses: number[] = [120, 80, 50];
let total: number = expenses.reduce((sum: number, current: number): number => {
  return sum + current;
}, 0);

console.info(total); // 250
```

### Transforming Data with Arrays

```typescript
interface UserRecord {
  name: string;
  score: number;
}

let users: UserRecord[] = [
  { name: 'Ada', score: 92 },
  { name: 'Grace', score: 88 }
];

let labels: string[] = users.map((user: UserRecord): string => {
  return `${user.name}: ${user.score}`;
});

console.info(labels.join(' | '));
```

Arrays are often the clearest collection when the program processes values in sequence and produces derived output.

## Sets

A `Set<T>` stores unique values:

```typescript
let tags: Set<string> = new Set<string>();
tags.add('arkts');
tags.add('guide');
tags.add('arkts');

console.info(tags.size); // 2
```

Use a set when membership matters more than ordering, and duplicates should be ignored automatically.

Sets are iterated in insertion order. That means values come back in the order they were first added, even though the main purpose of a set is uniqueness rather than indexed access.

Sets are useful for:

- feature flags
- visited states
- selected identifiers
- deduplicated labels

## Creating and Updating Sets

Create an empty set and add values:

```typescript
let enabled: Set<string> = new Set<string>();
enabled.add('wifi');
enabled.add('bluetooth');
```

You can also initialize a set from an array:

```typescript
let uniqueScores: Set<number> = new Set<number>([95, 88, 95, 76]);
console.info(uniqueScores.size); // 3
```

Check membership with `has()` and remove values with `delete()`:

```typescript
console.info(enabled.has('wifi'));      // true
console.info(enabled.has('location'));  // false

enabled.delete('bluetooth');
console.info(enabled.size); // 1
```

Clear the whole set when needed:

```typescript
enabled.clear();
console.info(enabled.size); // 0
```

## Iterating Over Sets

Iterate over a set with `for...of`:

```typescript
let permissions: Set<string> = new Set<string>(['read', 'write']);

for (let permission of permissions) {
  console.info(permission);
}
```

Because sets are built around uniqueness, they are often used together with arrays:

```typescript
let rawTags: string[] = ['arkts', 'guide', 'arkts', 'syntax'];
let uniqueTags: Set<string> = new Set<string>(rawTags);
let orderedTags: string[] = Array.from(uniqueTags);

console.info(orderedTags.join(', '));
```

This is an easy way to remove duplicates from a list while staying in typed collection APIs.

## Maps

A `Map<K, V>` stores key-value associations:

```typescript
let capitals: Map<string, string> = new Map<string, string>();
capitals.set('China', 'Beijing');
capitals.set('France', 'Paris');

console.info(capitals.get('China')); // Beijing
```

Maps are the preferred collection when values are looked up by a key instead of position.
Like sets, maps preserve insertion order when you iterate over their entries.

Use a map when:

- keys are not array indices
- the set of keys is discovered over time
- key-value lookup is the main operation
- a plain object would otherwise be used as a dictionary

### Maps vs Plain Objects

In JavaScript, plain objects are often used as ad hoc dictionaries. That is not the right default in ArkTS.

Use a `Map<K, V>` when keys are data discovered at runtime:

```typescript
let labels: Map<string, string> = new Map<string, string>();
labels.set('home.title', 'Home');
labels.set('profile.title', 'Profile');
```

Use a class or interface when the property names are fixed and part of the data model:

```typescript
interface UserProfile {
  name: string;
  city: string;
}

let profile: UserProfile = {
  name: 'Ada',
  city: 'London'
};
```

This distinction matters in ArkTS because indexed signatures and JavaScript-style dynamic object expansion are restricted.

## Creating and Updating Maps

Create an empty map and add entries with `set()`:

```typescript
let counters: Map<string, number> = new Map<string, number>();
counters.set('views', 10);
counters.set('likes', 3);
```

A later `set()` with the same key replaces the previous value:

```typescript
counters.set('views', 11);
```

You can also initialize a map from entry pairs:

```typescript
let statusCodes: Map<number, string> = new Map<number, string>([
  [200, 'OK'],
  [404, 'Not Found']
]);
```

### Reading from Maps

Use `get()` to read a value. Because the key may be absent, `get()` returns `V | undefined`:

```typescript
let currentViews: number | undefined = counters.get('views');
if (currentViews !== undefined) {
  console.info(currentViews);
}
```

Use `has()` when you specifically want to test whether a key exists:

```typescript
if (counters.has('likes')) {
  console.info('likes key exists');
}
```

When updating based on the current value, handle the missing case explicitly:

```typescript
function incrementCounter(store: Map<string, number>, key: string): void {
  let currentValue: number | undefined = store.get(key);
  if (currentValue === undefined) {
    store.set(key, 1);
  } else {
    store.set(key, currentValue + 1);
  }
}
```

## Iterating Over Maps

Use map iterator APIs instead of dynamic object enumeration:

```typescript
for (let entry of counters.entries()) {
  console.info(`${entry[0]}: ${entry[1]}`);
}
```

You can also iterate over keys or values separately:

```typescript
for (let key of counters.keys()) {
  console.info(key);
}

for (let value of counters.values()) {
  console.info(value);
}
```

If you need a stable textual report, a map can be traversed and formatted directly:

```typescript
function printSettings(settings: Map<string, string>): void {
  for (let entry of settings.entries()) {
    console.info(`${entry[0]} = ${entry[1]}`);
  }
}
```

## Choosing the Right Collection

Choose the collection that matches the shape of the data:

- Use `T[]` for ordered sequences.
- Use `Set<T>` for unique values and membership checks.
- Use `Map<K, V>` for key-value associations.

These choices are not interchangeable style preferences. They communicate how the data should be read and updated.

For example:

- a to-do list is usually `Task[]`
- enabled modules are usually `Set<string>`
- localized labels keyed by identifier are usually `Map<string, string>`

Avoid choosing a container only because it is familiar from JavaScript. In ArkTS, explicit typed containers are usually clearer and safer.

## Patterns for Nested Collections

Collections can contain other collections:

```typescript
let matrix: number[][] = [
  [1, 2, 3],
  [4, 5, 6]
];

console.info(matrix[1][2]); // 6
```

Maps can store arrays:

```typescript
let groups: Map<string, string[]> = new Map<string, string[]>();
groups.set('editors', ['Ada', 'Grace']);
groups.set('reviewers', ['Linus']);
```

Sets can also be used inside maps when each key needs unique values:

```typescript
let rolePermissions: Map<string, Set<string>> = new Map<string, Set<string>>();
rolePermissions.set('admin', new Set<string>(['read', 'write', 'delete']));
rolePermissions.set('viewer', new Set<string>(['read']));
```

Nested collections are useful, but keep the type readable. If a declaration becomes hard to understand, introduce a named class or interface around the data.

## Practical Collection Patterns

### Deduplicating a List

```typescript
function uniqueNames(names: string[]): string[] {
  return Array.from(new Set<string>(names));
}

console.info(uniqueNames(['Ada', 'Ada', 'Grace']).join(', ')); // Ada, Grace
```

### Grouping Values by Key

```typescript
function addToGroup(store: Map<string, string[]>, key: string, value: string): void {
  let current: string[] | undefined = store.get(key);
  if (current === undefined) {
    store.set(key, [value]);
  } else {
    current.push(value);
  }
}

let teams: Map<string, string[]> = new Map<string, string[]>();
addToGroup(teams, 'editors', 'Ada');
addToGroup(teams, 'editors', 'Grace');
```

### Counting Occurrences

```typescript
function countWords(words: string[]): Map<string, number> {
  let counts: Map<string, number> = new Map<string, number>();

  for (let word of words) {
    let current: number | undefined = counts.get(word);
    if (current === undefined) {
      counts.set(word, 1);
    } else {
      counts.set(word, current + 1);
    }
  }

  return counts;
}
```

These patterns appear often in parsing, analytics, and UI state management.

## ArkTS Restrictions That Affect Collections

ArkTS intentionally avoids several dynamic collection-like patterns from TypeScript and JavaScript:

- indexed signatures are not supported
- object layout cannot be changed at runtime
- dynamic property access is restricted
- many JavaScript dictionary patterns should become `Map<K, V>`
- examples that rely on destructuring should often be rewritten with explicit indexing or property access

That means a plain object should not be taught as a generic dictionary:

```typescript
// Avoid JavaScript-style dictionary patterns such as:
// let settings = {};
// settings['theme'] = 'dark';
```

Prefer a typed `Map` instead:

```typescript
let settings: Map<string, string> = new Map<string, string>();
settings.set('theme', 'dark');
settings.set('language', 'en-US');
```

Similarly, do not use `for...in` to traverse collection-like data:

```typescript
for (let item of ['a', 'b', 'c']) {
  console.info(item);
}
```

Typed arrays such as `Int32Array` also exist in ArkTS, but they serve more specialized numeric-storage scenarios. For most everyday collection code, ordinary arrays, sets, and maps are the right starting point.

ArkTS collection code should make the data model explicit. If the program needs ordered values, use an array. If it needs uniqueness, use a set. If it needs key-value lookup, use a map. This fits ArkTS's static object model much better than dynamic object tricks.

For loop syntax and branching around collections, see `control-flow.md`. For generic container definitions, see `generics.md`.
