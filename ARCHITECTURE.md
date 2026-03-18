## Webviz Architecture

This document describes the high‑level architecture of this repository, with a focus on how ROS/rosbag data flows through Webviz and how you can plug in other data formats or backend services.

---

## Repository Overview

- **Root**
  - **Build & tooling**: `package.json`, `lerna.json`, `webpack.config.js`, `babel.config.js`, `jest/` configure the monorepo, bundling, and tests.
  - **CI & Docker**:
    - `.circleci/` – CI configuration and screenshot comparison helpers.
    - `Dockerfile-static-webviz`, `Dockerfile-webviz-ci` – images for static Webviz and CI.
  - **Docs & stories**:
    - `docs/` – documentation site (React + MDX), good for conceptual explanations of panels and worldview.
    - `stories/` – Storybook configuration and stories for visual regression and component development.

- **Packages**
  - **`packages/webviz-core`**
    - The main Webviz application: panels, data pipeline, players, and data providers. This is where ROS / rosbag handling lives.
  - **`packages/regl-worldview`**
    - Low‑level 3D visualization engine using `regl`/WebGL (markers, point clouds, etc.).
  - **`packages/@cruise-automation/*`**
    - Reusable UI libraries such as `button`, `tooltip`, and `hooks` used across Webviz.

At a high level, the flow is:

**DataProviders → Player → MessagePipeline / PanelAPI → Panels (React UI) → `regl-worldview` (for 3D)**.

---

## `webviz-core` Structure

Within `packages/webviz-core/src`:

- **`components/`**
  - Generic React components and infrastructure, including the message pipeline, layout, and shared UI pieces.

- **`panels/`**
  - All visualization panels (Plot, Image, Raw Messages, Node graph, etc.).
  - Panels typically consume data via hooks from `PanelAPI/`, rather than talking to data providers or players directly.

- **`PanelAPI/`**
  - React hooks that expose the data stream to panels, e.g.:
    - `useMessagesByTopic`
    - `useBlocksByTopic` / `useBlocksByTopicWithFallback`
    - `useDataSourceInfo`
    - `useMessageReducer`
  - These hooks are backed by the current `PlayerState`, abstracting away where the data came from (bag, rosbridge, custom provider, etc.).

- **`players/`**
  - Implementations of the core **`Player` interface** (see `players/types.js`).
  - Responsible for:
    - Managing playback state (play, pause, seek, current time).
    - Managing subscriptions (which topics are requested in which formats).
    - Exposing a unified `PlayerState` to the UI.
  - Key players:
    - `RandomAccessPlayer` – bag‑style, seekable playback over a `DataProvider` tree.
    - `RosbridgePlayer` – live ROS connection via `rosbridge_server` and `roslibjs`.
    - `AutomatedRunPlayer` – automated, scripted runs using a data provider.
    - `UserNodePlayer` – wraps another player and injects user‑defined computation nodes.

- **`dataProviders/`**
  - The actual data sources and transforms. Each **`DataProvider`** implements a standard contract and can be composed into trees.
  - Examples:
    - `BagDataProvider` – reads rosbag files with the `rosbag` JS library.
    - `ParseMessagesDataProvider` – parses raw ROS binary messages into JS objects.
    - `CombinedDataProvider` – merges multiple providers into a single logical source.
    - `MemoryDataProvider` / `MemoryCacheDataProvider` – in‑memory data and caching.
    - `WorkerDataProvider` – runs a provider tree inside a Web Worker.
    - `RpcDataProvider` / `RpcDataProviderRemote` – generic RPC bridge for running providers in another JS context (worker or server).
    - `ApiCheckerDataProvider`, `MeasureDataProvider`, `IdbCacheWriterDataProvider`, etc. – instrumentation, caching, and validation layers.

- **`util/`**
  - Shared utilities for ROS types, message parsing, caching, time handling, and binary object handling, e.g.:
    - `MessageReaderStore` – caches `rosbag` `MessageReader` instances per datatype.
    - `bagConnectionsHelper` – converts bag connection metadata into datatypes.
    - `binaryObjects/` – utilities for “bobjects” (binary object wrappers for performance).
    - Time helpers, logging, notifications, etc.

- **`store/`, `reducers/`, `actions/`**
  - Redux store and reducers for layout, panel configuration, recent layouts, etc.

The rest of the app (styles, stories, tests) sits around this core.

---

## Core Data Model

Webviz is designed around a generic stream of **messages over time**, grouped into **topics** with **datatypes** and **message definitions**.

- **Topics**
  - Identified by a string name (e.g. `/camera/image`, `/tf`).
  - Associated with a datatype string (e.g. `sensor_msgs/Image`), but the system itself is agnostic to the actual schema as long as it is internally consistent.

- **Datatypes & message definitions**
  - Represented using ROS‑style message definitions (string definitions that can be parsed into fields).
  - Parsed into `RosDatatypes` (a map from datatype name to field metadata) using helpers like `parseMessageDefinition` and `bagConnectionsToDatatypes`.

- **Messages**
  - Each message has:
    - `topic`
    - `receiveTime` (or stamp‑based time, depending on configuration)
    - `message` payload (either:
      - raw binary (rosbag, CBOR),
      - parsed JS object, or
      - “bobject” – a binary‑oriented object representation).

This model is used by both offline bag playback and live ROS streaming, and it is flexible enough to represent non‑ROS data as well.

---

## Players

The **`Player` interface** (see `players/types.js`) abstracts where data comes from and how playback is controlled.

- **Responsibilities**
  - Maintain playback state:
    - Current time, start/end time, playback speed.
    - Whether the player is playing or paused.
  - Manage topic subscriptions:
    - Which topics are subscribed and in which formats (parsed messages, bobjects, raw binary).
  - Emit `PlayerState` via a listener:
    - The UI registers a listener with `setListener(listener: PlayerState => Promise<void>)`.
    - The player calls this whenever the state changes, and respects back‑pressure based on the returned promise.

- **Key implementations**
  - **Bag‑based playback**
    - `RandomAccessPlayer` (and related players) use a `DataProvider` tree as the underlying source, which is typically rooted at `BagDataProvider` for rosbag files.
  - **Live ROS**
    - `RosbridgePlayer` connects to a `rosbridge_server` WebSocket using `roslibjs`, manages subscriptions to topics, and uses `MessageReader` to decode CBOR‑encoded ROS messages.
  - **Other players**
    - `AutomatedRunPlayer`, `UserNodePlayer`, `StoryPlayer`, `OrderedStampPlayer`, `FakePlayer`, etc., build on or wrap the basic contract to support more advanced workflows (automated runs, user nodes, testing, etc.).

`PlayerManager` is the React/Redux‑side component that owns a `Player` instance, keeps its configuration, and exposes `PlayerState` to the rest of the app.

---

## Data Providers

**DataProviders** are the core primitive for sourcing and transforming data. Each provider implements an interface defined in `dataProviders/types.js`, including:

- `initialize(extensionPoint: ExtensionPoint): Promise<InitializationResult>`
- `getMessages(start: Time, end: Time, topics: GetMessagesTopics): Promise<GetMessagesResult>`
- `close(): Promise<void>`

Where:

- **`InitializationResult`** typically contains:
  - `start` and `end` time of the available data.
  - `topics` (name, datatype, etc.).
  - `messageDefinitions` (textual definitions per datatype).
  - Flags like `providesParsedMessages`.

- **`GetMessagesResult`** includes:
  - `parsedMessages`: array of `{ topic, receiveTime, message }` JS objects.
  - Optionally `bobjects` and/or `rosBinaryMessages`.

Providers are composed into trees via `DataProviderDescriptor` objects and built using helpers like `rootGetDataProvider` and `createGetDataProvider`.

### BagDataProvider (rosbag files)

- Uses the `rosbag` JS library to open `.bag` files:
  - Input can be:
    - A browser `File` (user‑uploaded) or
    - A remote URL (via `BrowserHttpReader`).
- `getMessages(start, end, subscriptions)`:
  - Calls `this._bag.readMessages` with `noParse: true`, returning raw binary blobs and connection metadata.
  - Handles decompression of `bz2` and `lz4` chunks using `compressjs` and `wasm-lz4`.
  - Emits an array of messages where `message` is a binary buffer slice (ROS wire format).

### ParseMessagesDataProvider (binary → JS objects)

- Sits directly above `BagDataProvider` (often with `MemoryCacheDataProvider` underneath).
- Uses `ParsedMessageCache` and `MessageReaderStore` to convert raw binary messages into typed JS objects:
  - `MessageReaderStore`:
    - Holds `MessageReader` instances from `rosbag`, each created from a parsed ROS message definition.
    - Given an MD5 and message definition text, constructs a reader and caches it.
    - At runtime, decodes binary buffers into plain JS objects.

### CombinedDataProvider and others

- **`CombinedDataProvider`**
  - Merges multiple child providers:
    - Unifies topic lists and datatypes.
    - Determines global start/end time.
    - Merges message definitions, handling conflicts.
  - Useful for multiple bag files or mixing different sources.

- **`MemoryDataProvider` / `MemoryCacheDataProvider`**
  - Hold message sets in memory and provide fast access, often used together with parsing for efficient seeking and replay.

- **`MeasureDataProvider`, `ApiCheckerDataProvider`, `IdbCacheWriterDataProvider`**
  - Wrap an existing provider to:
    - Measure performance / record usage.
    - Validate that the provider API is used correctly.
    - Cache data (e.g. in IndexedDB).

### WorkerDataProvider and RPC

- **`WorkerDataProvider`**
  - Wraps a child `DataProviderDescriptor` tree in a Web Worker.
  - Uses `RpcDataProvider` under the hood to send `initialize` and `getMessages` requests to the worker, keeping heavy parsing and IO off the main thread.

- **`RpcDataProvider` / `RpcDataProviderRemote`**
  - `RpcDataProvider` implements the `DataProvider` interface and forwards calls across an `Rpc` channel.
  - `RpcDataProviderRemote` implements the other side:
    - Receives `initialize` and `getMessages` requests.
    - Instantiates a real `DataProvider` tree and delegates to it.
    - Sends back responses, as well as progress and metadata callbacks.
  - This abstraction is intentionally generic:
    - It can run in a Web Worker, or
    - It can run on a backend server reachable via WebSocket that implements the same RPC protocol.

---

## ROS / Rosbag Data Flow

### 1. Offline rosbag files

The typical offline bag pipeline looks like:

1. **Raw bag access** – `BagDataProvider`
   - Opens a rosbag file (local `File` or remote URL).
   - Uses `rosbag` to:
     - Enumerate connections (topics, datatypes, message definitions).
     - Read chunks of messages over a requested time range.
   - Exposes messages as raw binary plus metadata.

2. **Binary → JS parsing** – `ParseMessagesDataProvider`
   - Receives raw binary messages from `BagDataProvider`.
   - Uses `MessageReaderStore` and ROS message definitions to parse into JS objects.
   - Maintains a small cache to make back‑and‑forth seeking efficient, assuming the lower‑level provider returns stable message references.

3. **Composition & caching** – `CombinedDataProvider`, `MemoryCacheDataProvider`, etc.
   - Optionally combine multiple bags or wrap with cache/instrumentation providers.
   - Present a single logical data source with unified topics and datatypes.

4. **Player** – typically `RandomAccessPlayer`
   - Owns the root `DataProvider`.
   - Calls `provider.initialize()` to get:
     - `start` / `end` time.
     - `topics`.
     - `messageDefinitions` and `RosDatatypes`.
   - During playback:
     - Calls `provider.getMessages(start, end, topicSelection)` according to playback position.
     - Receives `parsedMessages` / `bobjects` / `rosBinaryMessages` and forwards them as `PlayerState`.

5. **UI consumption** – `MessagePipeline` & `PanelAPI`
   - `PlayerManager` holds the `Player` and exposes `PlayerState`.
   - `PanelAPI` hooks subscribe to messages, blocks, or metadata and feed them into panels.

### 2. Live ROS via rosbridge

For live ROS systems, `RosbridgePlayer` is used instead of a bag‑backed `Player`:

1. **Connection**
   - `RosbridgePlayer` connects to `rosbridge_server` via WebSocket using `roslibjs`.

2. **Discovery**
   - Requests topics and message definitions from ROS (e.g. via services or parameters).
   - Converts that into:
     - A list of topics (`Topic[]`).
     - A `RosDatatypes` map using helpers like `parseMessageDefinition` and `bagConnectionsToDatatypes`.

3. **Subscriptions & parsing**
   - For each subscribed topic:
     - Creates a `ROSLIB.Topic` with `compression: "cbor-raw"`.
     - Receives messages as CBOR‑encoded binary blobs.
     - Uses `MessageReader` instances (the same mechanism used for bags) to decode `message.bytes` into JS objects.
   - Enqueues:
     - Parsed JS messages (for panels that want objects).
     - Bobjects (for panels that are optimized around binary objects).

4. **Playback**
   - Uses `Date.now()` for time (no seeking/simulated time support yet).
   - Emits `PlayerState` snapshots whenever new messages arrive or subscriptions change.

From the UI’s perspective, a live `RosbridgePlayer` and a bag‑backed `Player` both present the same high‑level API, so panels generally don’t care which one is active.

---

## UI & Panel Data Consumption

The React UI consumes data through a few well‑defined layers:

- **PlayerManager / MessagePipeline components**
  - Manage a `Player` instance and expose its `PlayerState` through a context or Redux store.

- **PanelAPI hooks**
  - Provide ergonomic access to the data model:
    - `useMessagesByTopic` – get messages for one or more topics over time.
    - `useBlocksByTopic` – block‑based access for large data streams.
    - `useDataSourceInfo` – topics, datatypes, and metadata about the current data source.
  - These hooks hide all details about Players and DataProviders.

- **Panels**
  - Implement domain‑specific rendering (e.g. plots, images, 3D scenes).
  - Use `PanelAPI` to subscribe to topics and render based on the incoming messages.

3D visualization panels delegate to `regl-worldview`, which handles low‑level WebGL details.

---

## Extending Webviz for Other Formats

The architecture is intentionally designed so that most of the system (players, PanelAPI, panels) is **format‑agnostic**. The only expectation is that data be exposed in terms of topics, datatypes, message definitions, and messages over time.

There are two main extension strategies:

### Strategy 1: New DataProvider for a different format

You can add support for a new data source (e.g. JSON logs, protobuf streams, custom DB queries) by implementing a new `DataProvider`:

- **Implement the DataProvider interface**
  - `initialize` should:
    - Discover available topics and their datatypes.
    - Provide textual message definitions (often easiest to model as ROS‑like `.msg` definitions, but they can be synthetic).
    - Compute overall `start` and `end` time.
  - `getMessages(start, end, topics)` should:
    - Read the underlying data source over the requested time range.
    - Return `parsedMessages` (JS objects) and optionally `bobjects` or binary representations.

- **Expose a ROS‑like schema**
  - Even if your data is not ROS, panels generally care about:
    - Topic names.
    - Datatype names.
    - Field structure (fields with type, name, array info).
  - You can create a synthetic ROS‑style schema that mirrors your real data model, then map your records into that schema.
  - This keeps existing generic panels (Plot, Raw Messages, etc.) working with minimal changes.

- **Compose into the existing tree**
  - Use the existing `DataProviderDescriptor` + `rootGetDataProvider` mechanism to:
    - Wrap your provider in caches (`MemoryCacheDataProvider`).
    - Combine it with other providers (`CombinedDataProvider`).
    - Run it in a Web Worker (`WorkerDataProvider`) if it is expensive.

Because the `Player` and `PanelAPI` already speak in terms of this generic data model, they do not need to change when you add a new provider.

### Strategy 2: Backend service via RpcDataProvider

If you want a **backend service** to handle heavy lifting (e.g. large datasets, proprietary formats, or server‑side indexing), you can implement the DataProvider protocol on the server side and use the existing RPC layer:

- **Browser side**
  - Use `RpcDataProvider` as your root provider (or wrap it inside other providers).
  - Have it talk to a WebSocket connection to your backend instead of a Web Worker.

- **Server side**
  - Implement the same logical interface as `RpcDataProviderRemote`:
    - Accept `initialize` and `getMessages` requests.
    - Internally, read from any data source or format you like.
    - Return `InitializationResult` / `GetMessagesResult` JSON over the wire.
    - Optionally forward progress and metadata events.

- **Benefits**
  - You preserve the same Player and Panel APIs on the client.
  - You can centralize access control, caching, and heavy parsing in your backend.
  - You can support non‑ROS formats or multiple heterogeneous sources behind a single logical provider tree.

### Strategy 3: Live non‑ROS streams

For live data sources that are not ROS (e.g. Kafka topics, custom WebSocket streams), you have two options:

- **Implement a new Player**
  - Similar to `RosbridgePlayer`, tailored to your streaming protocol.
  - Internally, map the incoming events into topics, datatypes, and messages over time.
  - Emit `PlayerState` the same way `RosbridgePlayer` does.

- **Or implement a streaming DataProvider**
  - If your stream can be represented as time‑indexed data, you can:
    - Wrap the streaming client inside a `DataProvider`.
    - Implement `initialize` + `getMessages` in a way that respects the time model.
  - Then use an existing Player that expects a `DataProvider` (e.g. `RandomAccessPlayer` for seekable sources, or a simpler custom player for append‑only streams).

In both cases, as long as the final output conforms to the topic/datatype/message model, the rest of Webviz will behave the same as it does for ROS.

---

## Summary

- The repo is a monorepo centered around `webviz-core`, with supporting UI libs and a 3D engine in `regl-worldview`.
- `webviz-core` implements a layered architecture:
  - **DataProviders** (data sources & transforms) →
  - **Players** (playback & subscriptions) →
  - **MessagePipeline / PanelAPI** →
  - **Panels** and **regl-worldview** (rendering).
- ROS/rosbag support is built into `BagDataProvider`, `ParseMessagesDataProvider`, `MessageReaderStore`, and `RosbridgePlayer`, but everything above that layer is largely format‑agnostic.
- To support other formats or a backend service, implement the `DataProvider` (and optionally `Player`) contracts, model your data in terms of topics/datatypes/message definitions, and plug into the existing composition and RPC mechanisms.

