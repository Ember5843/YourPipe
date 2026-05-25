/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Basic implementation of data listening with IDataSource.
 */
export abstract class BasicDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];

  // Get the length of the array.
  public abstract totalCount(): number;

  // Retrieve data at the specified index.
  public getData(index: number): void {
  }

  // Add a listener to the data source for the LazyForEach component.
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  // Remove the listener from the data source for the corresponding LazyForEach component.
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  // Notify the LazyForEach component to reload all its child components.
  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  // Notify the LazyForEach component to add a child component at the index corresponding to the specified index.
  notifyDataAdd(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataAdd(index);
    })
  }

  // Notify the LazyForEach component that there is a change in the data at the index corresponding to the specified
  // index, and that the child component at this index needs to be rebuilt.
  notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    })
  }

  // Notify the LazyForEach component to remove the child component at the index corresponding to the specified index.
  notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    })
  }
}