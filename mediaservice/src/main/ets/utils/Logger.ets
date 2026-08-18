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

import { EnhancedLogger } from './EnhancedLogger';

/**
 * mediaservice 共享模块日志实例（EnhancedLogger 的默认入口）。
 * 需要独立标签的组件请用 EnhancedLogger.getInstance(prefix, ...tags)。
 */
export default EnhancedLogger.getInstance('[Mediaservice]');
