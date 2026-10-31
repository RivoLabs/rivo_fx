---@meta rivo_fx
-- LuaLS definitions for Rivo FX. Point your .luarc.json at this folder:
--   { "workspace.library": ["path/to/rivo_fx/types"] }
-- Generics give autocomplete and value types; the error channel E is
-- best-effort (LuaLS cannot infer unions of error tables).

---The type of a value that never exists (an effect that never succeeds or never fails).
---@alias never nil

---@class Fx.Cause
---@field _tag "Empty"|"Fail"|"Die"|"Interrupt"|"Sequential"|"Parallel"

---@class Fx.Exit<A>
---@field _tag "Success"|"Failure"
---@field value A|nil
---@field cause Fx.Cause|nil

---@class Fx.TaggedError
---@field _tag string
---@field message? string
local TaggedError = {}
---@return Fx.Effect<never, Fx.TaggedError>
function TaggedError:fail() end

---@class Fx.TaggedErrorClass
---@field _tag string
---@overload fun(props?: table): Fx.TaggedError
local TaggedErrorClass = {}
---@param v any
---@return boolean
function TaggedErrorClass.is(v) end

---@class Fx.Effect<A, E>
local Effect = {}

---@generic A, B
---@param self Fx.Effect<A, any>
---@param f fun(a: A): B
---@return Fx.Effect<B, any>
function Effect:map(f) end

---@generic A, B
---@param self Fx.Effect<A, any>
---@param f fun(a: A): Fx.Effect<B, any>
---@return Fx.Effect<B, any>
function Effect:flatMap(f) end

---@generic A, B
---@param self Fx.Effect<A, any>
---@param f (fun(a: A): (Fx.Effect<B, any>|B))|Fx.Effect<B, any>
---@return Fx.Effect<B, any>
function Effect:andThen(f) end

---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(a: A): any
---@return Fx.Effect<A, any>
function Effect:tap(f) end

---@generic B
---@param v B
---@return Fx.Effect<B, any>
function Effect:as(v) end
---@return Fx.Effect<nil, any>
function Effect:asVoid() end
---@generic B
---@param that Fx.Effect<B, any>
---@return Fx.Effect<B, any>
function Effect:zipRight(that) end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:zipLeft(that) end
---@return Fx.Effect<table, any>
function Effect:zip(that) end

---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(e: any): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:catchAll(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(c: Fx.Cause): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:catchAllCause(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(defect: any): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:catchAllDefect(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param tag string
---@param f fun(e: Fx.TaggedError|table): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:catchTag(tag, f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param handlers table<string, fun(e: table): Fx.Effect<A, any>>
---@return Fx.Effect<A, any>
function Effect:catchTags(handlers) end
---@generic A
---@param self Fx.Effect<A, any>
---@param pred fun(e: any): boolean
---@param f fun(e: any): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:catchIf(pred, f) end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:mapError(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:tapError(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:tapErrorCause(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:orElse(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param v A
---@return Fx.Effect<A, never>
function Effect:orElseSucceed(v) end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, never>
function Effect:orDie() end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<{ ok: boolean, value: A|nil, error: any }, never>
function Effect:result() end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A|nil, never>
function Effect:option() end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<Fx.Exit<A>, never>
function Effect:exit() end
---@generic A
---@param self Fx.Effect<A, any>
---@param handlers { onFailure: fun(e: any): any, onSuccess: fun(a: A): any }
---@return Fx.Effect<any, never>
function Effect:match(handlers) end
---@generic A
---@param self Fx.Effect<A, any>
---@param handlers { onFailure: fun(e: any): Fx.Effect<any, any>, onSuccess: fun(a: A): Fx.Effect<any, any> }
---@return Fx.Effect<any, any>
function Effect:matchEffect(handlers) end
---@generic A
---@param self Fx.Effect<A, any>
---@param pred fun(a: A): boolean
---@param onFalse fun(a: A): any
---@return Fx.Effect<A, any>
function Effect:filterOrFail(pred, onFalse) end

---@generic A
---@param self Fx.Effect<A, any>
---@param ms integer
---@return Fx.Effect<A, any>
function Effect:delay(ms) end
---@return Fx.Effect<never, any>
function Effect:forever() end
---Fail with TimeoutError after ms.
---@generic A
---@param self Fx.Effect<A, any>
---@param ms integer
---@return Fx.Effect<A, any>
function Effect:timeout(ms) end
---Run inside a new span, the child of the current one.
---@generic A, E
---@param self Fx.Effect<A, E>
---@param name string
---@param opts? Fx.SpanOptions
---@return Fx.Effect<A, E>
function Effect:withSpan(name, opts) end
---Observe how long this takes (ms) in a histogram.
---@generic A, E
---@param self Fx.Effect<A, E>
---@param histogram Fx.Histogram
---@param labels? table<string, any>
---@return Fx.Effect<A, E>
function Effect:trackDuration(histogram, labels) end
---Count failures in a counter, labelled with the error tag.
---@generic A, E
---@param self Fx.Effect<A, E>
---@param counter Fx.Counter
---@param labels? table<string, any>
---@return Fx.Effect<A, E>
function Effect:trackErrors(counter, labels) end
---@generic A
---@param self Fx.Effect<A, any>
---@param ms integer
---@param onTimeout fun(): any
---@return Fx.Effect<A, any>
function Effect:timeoutFail(ms, onTimeout) end
---@generic A
---@param self Fx.Effect<A, any>
---@param ms integer
---@return Fx.Effect<A|nil, any>
function Effect:timeoutOption(ms) end
---@generic A
---@param self Fx.Effect<A, any>
---@param that Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:race(that) end
---@generic A
---@param self Fx.Effect<A, any>
---@param that Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:raceFirst(that) end

---@generic A
---@param self Fx.Effect<A, any>
---@param policy integer|Fx.Schedule|Fx.RetryPolicy
---@return Fx.Effect<A, any>
function Effect:retry(policy) end
---@generic A
---@param self Fx.Effect<A, any>
---@param schedule Fx.Schedule|integer
---@return Fx.Effect<A, any>
function Effect:repeatWith(schedule) end
---@generic A
---@param self Fx.Effect<A, any>
---@param n integer
---@return Fx.Effect<A, any>
function Effect:repeatN(n) end

---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:uninterruptible() end
---@generic A
---@param self Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Effect:interruptible() end
---@generic A
---@param self Fx.Effect<A, any>
---@param fin fun(exit: Fx.Exit<A>): Fx.Effect<any, any>
---@return Fx.Effect<A, any>
function Effect:onExit(fin) end
---@generic A
---@param self Fx.Effect<A, any>
---@param finalizer Fx.Effect<any, any>
---@return Fx.Effect<A, any>
function Effect:ensuring(finalizer) end
---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(cause: Fx.Cause): Fx.Effect<any, any>
---@return Fx.Effect<A, any>
function Effect:onError(f) end
---@generic A
---@param self Fx.Effect<A, any>
---@param f fun(): Fx.Effect<any, any>
---@return Fx.Effect<A, any>
function Effect:onInterrupt(f) end

---@return Fx.Effect<Fx.Fiber, never>
function Effect:fork() end
---@return Fx.Effect<Fx.Fiber, never>
function Effect:forkDaemon() end
---Requires Scope.
---@return Fx.Effect<Fx.Fiber, never>
function Effect:forkScoped() end

---@generic A
---@param self Fx.Effect<A, any>
---@param tag Fx.Tag
---@param service any
---@return Fx.Effect<A, any>
function Effect:provideService(tag, service) end
---@generic A
---@param self Fx.Effect<A, any>
---@param what Fx.Layer|table
---@return Fx.Effect<A, any>
function Effect:provide(what) end
---@generic A
---@param self Fx.Effect<A, any>
---@param ctx table
---@return Fx.Effect<A, any>
function Effect:provideContext(ctx) end

---Inside Fx.gen: run this effect and return its value.
---@generic A
---@param self Fx.Effect<A, any>
---@return A
function Effect:await() end

---@class Fx.Tag: Fx.Effect<any, never>
---@field key string

---@class Fx.Fiber
---@field id integer
---@field exit Fx.Exit|nil
local Fiber = {}
---@return Fx.Effect<Fx.Exit, never>
function Fiber:await() end
---@return Fx.Effect<any, any>
function Fiber:join() end
---@return Fx.Effect<Fx.Exit, never>
function Fiber:interrupt() end
---@param byId? integer
function Fiber:interruptAsFork(byId) end
---@param cb fun(exit: Fx.Exit)
---@return fun()
function Fiber:addObserver(cb) end

---Retry policy table. Also accepts `while = fun(e): boolean` and
---`until = fun(e): boolean` (Lua keywords, so not annotated here).
---@class Fx.RetryPolicy
---@field times? integer
---@field schedule? Fx.Schedule

---@class Fx.Schedule
local Schedule = {}
---@param n integer
---@return Fx.Schedule
function Schedule:take(n) end
---@return Fx.Schedule
function Schedule:jittered(min, max) end
---@param ms integer
---@return Fx.Schedule
function Schedule:maxDelay(ms) end
---@param ms integer
---@return Fx.Schedule
function Schedule:upTo(ms) end
---@param pred fun(input: any): boolean
---@return Fx.Schedule
function Schedule:whileInput(pred) end
---@param other Fx.Schedule
---@return Fx.Schedule
function Schedule:intersect(other) end
---@param other Fx.Schedule
---@return Fx.Schedule
function Schedule:union(other) end

---@class Fx.ScheduleModule
---@field forever Fx.Schedule
---@field once Fx.Schedule
---@field spaced fun(ms: integer): Fx.Schedule
---@field fixed fun(ms: integer): Fx.Schedule
---@field recurs fun(n: integer): Fx.Schedule
---@field exponential fun(base: integer, factor?: number): Fx.Schedule
---@field fibonacci fun(base: integer): Fx.Schedule

---@class Fx.ScopeObject
---@field closed boolean
local ScopeObject = {}
---@param fin fun(exit: Fx.Exit): Fx.Effect<any, any>
---@return Fx.Effect<nil, never>
function ScopeObject:addFinalizer(fin) end
---@param exit? Fx.Exit
---@return Fx.Effect<nil, never>
function ScopeObject:close(exit) end
---@return Fx.ScopeObject
function ScopeObject:fork() end
---@generic A
---@param eff Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function ScopeObject:extend(eff) end

---@class Fx.ScopeTag: Fx.Tag
---@field make fun(): Fx.Effect<Fx.ScopeObject, never>
---@field unsafeMake fun(): Fx.ScopeObject

---@class Fx.Layer
local Layer = {}
---@param dep Fx.Layer
---@return Fx.Layer
function Layer:provide(dep) end
---@param dep Fx.Layer
---@return Fx.Layer
function Layer:provideMerge(dep) end

---@class Fx.LayerModule
---@field empty Fx.Layer
---@field succeed fun(tag: Fx.Tag, service: any): Fx.Layer
---@field sync fun(tag: Fx.Tag, fn: fun(): any): Fx.Layer
---@field effect fun(tag: Fx.Tag, eff: Fx.Effect<any, any>): Fx.Layer
---@field scoped fun(tag: Fx.Tag, eff: Fx.Effect<any, any>): Fx.Layer
---@field effectDiscard fun(eff: Fx.Effect<any, any>): Fx.Layer
---@field merge fun(...: Fx.Layer): Fx.Layer

---@class Fx.Runtime
local Runtime = {}
---@param eff Fx.Effect<any, any>
---@param opts? { onExit?: fun(exit: Fx.Exit) }
---@return Fx.Fiber
function Runtime:runFork(eff, opts) end
---@generic A
---@param eff Fx.Effect<A, any>
---@return A
function Runtime:runAwait(eff) end
---@return Fx.Effect<nil, never>
function Runtime:dispose() end

---@class Fx.RuntimeModule
---@field make fun(layer: Fx.Layer): Fx.Runtime

---@class Fx.Schema<T>
local Schema = {}
---@generic T
---@param self Fx.Schema<T>
---@return boolean ok
---@return T|string valueOrMessage
function Schema:validate(input) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Effect<T, Fx.TaggedError>
function Schema:decode(input) end
---@generic T
---@param self Fx.Schema<T>
---@return T
function Schema:parse(input) end
---@return boolean
function Schema:is(input) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T|nil>
function Schema:optional() end
---@generic T
---@param self Fx.Schema<T>
---@param v T|fun(): T
---@return Fx.Schema<T>
function Schema:default(v) end
---@generic T
---@param self Fx.Schema<T>
---@param pred fun(v: T): (boolean, string?)
---@param message? string
---@return Fx.Schema<T>
function Schema:refine(pred, message) end
---@generic T, U
---@param self Fx.Schema<T>
---@param fn fun(v: T): U
---@return Fx.Schema<U>
function Schema:transform(fn) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:min(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:max(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:between(lo, hi) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:positive() end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:nonNegative() end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:minLen(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:maxLen(n) end
---String length in characters (UTF-8 code points), not bytes; invalid UTF-8 fails.
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:minChars(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:maxChars(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:len(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:nonEmpty() end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:minItems(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:maxItems(n) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:pattern(p, message) end
---@generic T
---@param self Fx.Schema<T>
---@return Fx.Schema<T>
function Schema:describe(text) end

---@class Fx.SchemaModule
---@field string Fx.Schema<string>
---@field number Fx.Schema<number>
---@field int Fx.Schema<integer>
---@field integer Fx.Schema<integer>
---@field boolean Fx.Schema<boolean>
---@field unknown Fx.Schema<any>
---@field any Fx.Schema<any>
---@field vector2 Fx.Schema<{ x: number, y: number }>
---@field vector3 Fx.Schema<{ x: number, y: number, z: number }>
---@field vector4 Fx.Schema<{ x: number, y: number, z: number, w: number }>
---@field hash Fx.Schema<integer>
---@field netId Fx.Schema<integer>
---@field player Fx.Schema<integer>
---@field literal fun(...: any): Fx.Schema<any>
---@field enum fun(values: any[]): Fx.Schema<any>
---@field array fun(item: Fx.Schema): Fx.Schema<any[]>
---@field tuple fun(...: Fx.Schema): Fx.Schema<any[]>
---@field struct fun(fields: table<string, Fx.Schema>, opts?: { extra?: "strip"|"error"|"keep" }): Fx.Schema<table>
---@field object fun(fields: table<string, Fx.Schema>, opts?: { extra?: "strip"|"error"|"keep" }): Fx.Schema<table>
---@field record fun(key: Fx.Schema, value: Fx.Schema): Fx.Schema<table>
---@field union fun(...: Fx.Schema): Fx.Schema<any>
---@field tagged fun(field: string, variants: table<string, Fx.Schema>): Fx.Schema<table>
---@field lazy fun(fn: fun(): Fx.Schema): Fx.Schema<any>

---@class Fx.Ref<A>
local Ref = {}
---@return Fx.Effect<any, never>
function Ref:get() end
---@return Fx.Effect<nil, never>
function Ref:set(v) end
---@param f fun(v: any): any
---@return Fx.Effect<nil, never>
function Ref:update(f) end
---@param f fun(v: any): any
---@return Fx.Effect<any, never>
function Ref:updateAndGet(f) end
---@param f fun(v: any): any, any
---@return Fx.Effect<any, never>
function Ref:modify(f) end

---@class Fx.Deferred
local Deferred = {}
---@return Fx.Effect<any, any>
function Deferred:await() end
---@return Fx.Effect<boolean, never>
function Deferred:succeed(v) end
---@return Fx.Effect<boolean, never>
function Deferred:fail(e) end
---@return boolean
function Deferred:isDone() end

---@class Fx.Semaphore
local Semaphore = {}
---@generic A
---@param eff Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Semaphore:withPermit(eff) end
---@generic A
---@param n integer
---@param eff Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Semaphore:withPermits(n, eff) end

---@class Fx.Queue
local Queue = {}
---@return Fx.Effect<boolean, never>
function Queue:offer(v) end
---@return Fx.Effect<any, never>
function Queue:take() end
---@return Fx.Effect<any, never>
function Queue:poll() end
---@return Fx.Effect<any[], never>
function Queue:takeAll() end
---@return Fx.Effect<integer, never>
function Queue:size() end

---@class Fx.PubSub
local PubSub = {}
---@return Fx.Effect<nil, never>
function PubSub:publish(v) end
---Requires Scope.
---@param opts? Fx.StreamBufferOptions
---@return Fx.Effect<Fx.Queue, never>
function PubSub:subscribe(opts) end
---@param fn fun(v: any)
---@return fun()
function PubSub:on(fn) end

---@alias Fx.Emit fun(v: any): Fx.Effect<boolean, any>

---Zero or more values over time. Nothing runs until a run* effect runs.
---@class Fx.Stream<A>
---@field run fun(emit: Fx.Emit): Fx.Effect<boolean, any>
local Stream = {}
---@param f fun(v: any): any
---@return Fx.Stream<any>
function Stream:map(f) end
---@param f fun(v: any): Fx.Effect<any, any>
---@return Fx.Stream<any>
function Stream:mapEffect(f) end
---@param pred fun(v: any): boolean
---@return Fx.Stream<any>
function Stream:filter(pred) end
---@param f fun(v: any): any
---@return Fx.Stream<any>
function Stream:filterMap(f) end
---@param f fun(v: any): Fx.Effect<any, any>|nil
---@return Fx.Stream<any>
function Stream:tap(f) end
---@param n integer
---@return Fx.Stream<any>
function Stream:take(n) end
---@param pred fun(v: any): boolean
---@return Fx.Stream<any>
function Stream:takeWhile(pred) end
---@param pred fun(v: any): boolean
---@return Fx.Stream<any>
function Stream:takeUntil(pred) end
---@param n integer
---@return Fx.Stream<any>
function Stream:drop(n) end
---@param pred fun(v: any): boolean
---@return Fx.Stream<any>
function Stream:dropWhile(pred) end
---@param init any
---@param f fun(acc: any, v: any): any
---@return Fx.Stream<any>
function Stream:scan(init, f) end
---@param eq? fun(a: any, b: any): boolean
---@return Fx.Stream<any>
function Stream:changes(eq) end
---@param n integer
---@return Fx.Stream<any[]>
function Stream:grouped(n) end
---@param n integer
---@param ms integer
---@return Fx.Stream<any[]>
function Stream:groupedWithin(n, ms) end
---@param ms integer
---@return Fx.Stream<any>
function Stream:debounce(ms) end
---@param ms integer
---@return Fx.Stream<any>
function Stream:throttle(ms) end
---@param f fun(v: any): Fx.Stream<any>
---@return Fx.Stream<any>
function Stream:flatMap(f) end
---@param that Fx.Stream<any>
---@return Fx.Stream<any>
function Stream:concat(that) end
---@param ... Fx.Stream<any>
---@return Fx.Stream<any>
function Stream:merge(...) end
---@param f fun(err: any): Fx.Stream<any>
---@return Fx.Stream<any>
function Stream:catchAll(f) end
---@param fin Fx.Effect<any, never>
---@return Fx.Stream<any>
function Stream:ensuring(fin) end
---@param ms integer
---@return Fx.Stream<any>
function Stream:interruptAfter(ms) end
---@param f fun(v: any): Fx.Effect<any, any>|nil
---@return Fx.Effect<nil, any>
function Stream:runForEach(f) end
---@param f fun(v: any): boolean|Fx.Effect<boolean, any>|nil
---@return Fx.Effect<nil, any>
function Stream:runForEachWhile(f) end
---@return Fx.Effect<nil, any>
function Stream:runDrain() end
---@return Fx.Effect<any[], any>
function Stream:runCollect() end
---@param init any
---@param f fun(acc: any, v: any): any
---@return Fx.Effect<any, any>
function Stream:runFold(init, f) end
---@return Fx.Effect<integer, any>
function Stream:runCount() end
---@return Fx.Effect<any, any>
function Stream:runHead() end
---@return Fx.Effect<any, any>
function Stream:runLast() end
---@param f? fun(v: any): Fx.Effect<any, any>|nil
---@return Fx.Effect<Fx.Fiber, never>
function Stream:runFork(f) end

---@class Fx.StreamBufferOptions
---@field buffer? integer
---@field strategy? "sliding"|"dropping"

---@class Fx.StreamModule
---@field empty Fx.Stream<never>
---@field never Fx.Stream<never>
---@field make fun(...: any): Fx.Stream<any>
---@field fromTable fun(list: any[]): Fx.Stream<any>
---@field range fun(from: integer, to?: integer): Fx.Stream<integer>
---@field iterate fun(seed: any, f: fun(v: any): any): Fx.Stream<any>
---@field fail fun(err: any): Fx.Stream<never>
---@field fromEffect fun(eff: Fx.Effect<any, any>): Fx.Stream<any>
---@field repeatEffect fun(eff: Fx.Effect<any, any>): Fx.Stream<any>
---@field interval fun(ms: integer): Fx.Stream<integer>
---@field fromSchedule fun(schedule: Fx.Schedule): Fx.Stream<integer>
---@field fromQueue fun(q: Fx.Queue): Fx.Stream<any>
---@field fromPubSub fun(ps: Fx.PubSub, opts?: Fx.StreamBufferOptions): Fx.Stream<any>
---@field async fun(register: fun(push: fun(v: any), finish: fun(err?: any)): (fun()|nil), opts?: Fx.StreamBufferOptions): Fx.Stream<any>
---@field event fun(name: string, shape?: function, opts?: Fx.StreamBufferOptions): Fx.Stream<any>
---@field merge fun(...: Fx.Stream<any>): Fx.Stream<any>
---@field fromRun fun(run: fun(emit: Fx.Emit): Fx.Effect<boolean, any>): Fx.Stream<any>
---@field isStream fun(v: any): boolean

---@class Fx.Span
---@field name string
---@field traceId string
---@field spanId string
---@field parentSpanId? string
---@field kind "internal"|"server"|"client"|"producer"|"consumer"
---@field startTime integer unix ms
---@field endTime? integer unix ms
---@field status "unset"|"ok"|"error"
---@field message? string
---@field attributes table<string, any>
---@field events { name: string, time: integer, attributes?: table }[]
---@field resource string
---@field seq? integer order of finishing in this resource (set when it ends)
local Span = {}
---@return Fx.Span
function Span:setAttribute(key, value) end
---@param attributes? table
---@return Fx.Span
function Span:addEvent(name, attributes) end
---@return string
function Span:traceparent() end

---@class Fx.SpanOptions
---@field attributes? table<string, any>
---@field kind? "internal"|"server"|"client"|"producer"|"consumer"
---@field parent? Fx.Span|string a span or a W3C traceparent
---@field root? boolean

---@class Fx.Trace
---@field CurrentSpan Fx.Tag
---@field on fun(fn: fun(span: Fx.Span)): fun()
---@field stream fun(opts?: { buffer?: integer }): Fx.Stream<Fx.Span>
---@field recent fun(after?: integer): Fx.Span[] oldest first; with after, only spans with a greater seq
---@field failedSpanOf fun(cause: Fx.Cause): Fx.Span|nil the innermost span a failure was raised in
---@field start fun(name: string, parent?: Fx.Span|{ traceId: string, spanId: string }, opts?: Fx.SpanOptions): Fx.Span
---@field finish fun(span: Fx.Span, exit?: Fx.Exit)
---@field parseTraceparent fun(s: string): { traceId: string, spanId: string, remote: boolean }|nil
---@field traceparentOf fun(fiber: Fx.Fiber): string|nil
---@field setEnabled fun(on: boolean)
---@field isEnabled fun(): boolean
---@field nowMs fun(): integer

---@class Fx.Counter
local Counter = {}
---@param n? number
---@param labels? table<string, any>
function Counter:inc(n, labels) end
---@param labels? table<string, any>
---@return number
function Counter:value(labels) end
---@return Fx.Effect<nil, never>
function Counter:update(n, labels) end

---@class Fx.Gauge
local Gauge = {}
---@param labels? table<string, any>
function Gauge:set(v, labels) end
---@param labels? table<string, any>
function Gauge:add(n, labels) end
---@param labels? table<string, any>
---@return number
function Gauge:value(labels) end
---@return Fx.Effect<nil, never>
function Gauge:update(v, labels) end

---@class Fx.Histogram
local Histogram = {}
---@param labels? table<string, any>
function Histogram:observe(v, labels) end
---@return Fx.Effect<nil, never>
function Histogram:update(v, labels) end

---@class Fx.MetricSnapshot
---@field name string
---@field kind "counter"|"gauge"|"histogram"
---@field help string
---@field buckets? number[]
---@field series { labels: table<string, string>, value?: number, counts?: integer[], sum?: number, count?: integer }[]

---@class Fx.Metrics
---@field counter fun(name: string, opts?: { help?: string }): Fx.Counter
---@field gauge fun(name: string, opts?: { help?: string, collect?: fun(): number|table }): Fx.Gauge
---@field histogram fun(name: string, opts?: { help?: string, buckets?: number[] }): Fx.Histogram
---@field snapshot fun(): Fx.MetricSnapshot[]
---@field prometheus fun(extraLabels?: table<string, string>, snapshot?: Fx.MetricSnapshot[]): string

---@class Fx.Log
---@field debug fun(msg: string, fields?: table)
---@field info fun(msg: string, fields?: table)
---@field warn fun(msg: string, fields?: table)
---@field error fun(msg: string, fields?: table)
---@field setLevel fun(level: "debug"|"info"|"warn"|"error"|"none")
---@field setSink fun(fn: (fun(level: string, msg: string, fields?: table))|nil)

---@class Fx.SecurityEvent
---@field kind "invalid_payload"|"rate_limited"|"unknown_rpc"|"invalid_state"
---@field source integer
---@field name string
---@field message? string
---@field resource string

---@class Fx.Security
---@field on fun(fn: fun(ev: Fx.SecurityEvent)): fun()
---@field subscribe fun(): Fx.Effect<Fx.Queue, never>
---@field stream fun(opts?: { buffer?: integer }): Fx.Stream<Fx.SecurityEvent>
---@field setQuiet fun(quiet: boolean)
---@field report fun(ev: { kind: string, source: integer, name: string, message?: string })

---Token bucket per key (a player id): "10/s", "30/m".
---@class Fx.RateLimiter
---@field take fun(self: Fx.RateLimiter, key: any): boolean
---@field forget fun(self: Fx.RateLimiter, key: any)

---@class Fx.RateLimiterModule
---@field new fun(spec: string): Fx.RateLimiter
---@field parse fun(spec: string): number, number

---@class Fx.NetOptions
---@field rateLimit? string|false
---@field runtime? Fx.Runtime
---@field playerScoped? boolean

---@class Fx.Net
local Net = {}
---Server: handler(src, input). Client: handler(input). Return an effect or nothing.
---@param name string
---@param schema Fx.Schema
---@param handler fun(srcOrInput: any, input?: any): Fx.Effect<any, any>|nil
---@param opts? Fx.NetOptions
---@return fun() remove
function Net.handle(name, schema, handler, opts) end
---Server: values are { source, input }. Client: values are the input.
---@param name string
---@param schema Fx.Schema
---@param opts? { rateLimit?: string|false, buffer?: integer, strategy?: "sliding"|"dropping" }
---@return Fx.Stream<any>
function Net.stream(name, schema, opts) end
---Server: send(name, target, payload). Client: send(name, payload).
function Net.send(name, ...) end
---Server: broadcast to every player.
function Net.broadcast(name, payload) end
---Effect version of send.
---@return Fx.Effect<nil, never>
function Net.emit(name, ...) end

---@class Fx.RpcSpec
---@field input Fx.Schema
---@field output? Fx.Schema
---@field rateLimit? string|false
---@field runtime? Fx.Runtime
---@field libCallback? boolean

---@class Fx.RpcCallOptions
---@field timeout? integer
---@field resource? string
---@field output? Fx.Schema

---@class Fx.Rpc
---@field RpcNotFound Fx.TaggedErrorClass
---@field RpcInvalidInput Fx.TaggedErrorClass
---@field RpcRateLimited Fx.TaggedErrorClass
---@field RpcInternalError Fx.TaggedErrorClass
---@field RpcTimeout Fx.TaggedErrorClass
---@field RpcInvalidOutput Fx.TaggedErrorClass
local Rpc = {}
---Server: handler(src, input). Client: handler(input).
---@param name string
---@param spec Fx.RpcSpec
---@param handler fun(srcOrInput: any, input?: any): any
---@return fun() unregister
function Rpc.register(name, spec, handler) end
---Client only.
---@param name string
---@param input any
---@param opts? Fx.RpcCallOptions
---@return Fx.Effect<any, Fx.TaggedError>
function Rpc.call(name, input, opts) end
---Server only.
---@param player integer
---@param name string
---@param input any
---@param opts? Fx.RpcCallOptions
---@return Fx.Effect<any, Fx.TaggedError>
function Rpc.callClient(player, name, input, opts) end

---@class Fx.Player
---@field scope fun(src: integer): Fx.ScopeObject
---@field extend fun(src: integer, eff: Fx.Effect<any, any>): Fx.Effect<any, any>
---@field fork fun(src: integer, eff: Fx.Effect<any, any>, opts?: table): Fx.Fiber
---@field onDrop fun(src: integer, fin: function|Fx.Effect<any, any>)

---@class Fx.Config
---@field ConfigError Fx.TaggedErrorClass
---@field string fun(name: string, default?: string): Fx.Effect<string, Fx.TaggedError>
---@field number fun(name: string, default?: number): Fx.Effect<number, Fx.TaggedError>
---@field int fun(name: string, default?: integer): Fx.Effect<integer, Fx.TaggedError>
---@field bool fun(name: string, default?: boolean): Fx.Effect<boolean, Fx.TaggedError>
---@field enum fun(name: string, values: string[], default?: string): Fx.Effect<string, Fx.TaggedError>
---@field json fun(name: string, schema: Fx.Schema, default?: any): Fx.Effect<any, Fx.TaggedError>
---@field struct fun(fields: table<string, Fx.Effect<any, any>>): Fx.Effect<table, Fx.TaggedError>
---@field file fun(path: string, schema: Fx.Schema, opts?: { resource?: string }): Fx.Effect<any, Fx.TaggedError>

---@class Fx.LoadOptions
---@field timeout? integer

---@class Fx.Assets
---@field AssetNotFound Fx.TaggedErrorClass
---@field AssetTimeout Fx.TaggedErrorClass
---@field model fun(model: string|integer, opts?: Fx.LoadOptions): Fx.Effect<integer, Fx.TaggedError>
---@field useModel fun(model: string|integer, opts?: Fx.LoadOptions): Fx.Effect<integer, Fx.TaggedError>
---@field animDict fun(dict: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field useAnimDict fun(dict: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field animSet fun(set: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field useAnimSet fun(set: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field ptfx fun(asset: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field usePtfx fun(asset: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field textureDict fun(dict: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field useTextureDict fun(dict: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field scaleform fun(name: string, opts?: Fx.LoadOptions): Fx.Effect<integer, Fx.TaggedError>
---@field useScaleform fun(name: string, opts?: Fx.LoadOptions): Fx.Effect<integer, Fx.TaggedError>
---@field audioBank fun(bank: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>
---@field useAudioBank fun(bank: string, opts?: Fx.LoadOptions): Fx.Effect<string, Fx.TaggedError>

---@class Fx.SpawnOptions
---@field networked? boolean
---@field timeout? integer
---@field pedType? integer

---@class Fx.Entity
---@field EntityGone Fx.TaggedErrorClass
---@field ControlTimeout Fx.TaggedErrorClass
---@field NetIdTimeout Fx.TaggedErrorClass
---@field SpawnFailed Fx.TaggedErrorClass
---@field exists fun(ent: integer): Fx.Effect<integer, Fx.TaggedError>
---@field delete fun(ent: integer): Fx.Effect<nil, never>
---@field fromNetId fun(netId: integer, opts?: { timeout?: integer }): Fx.Effect<integer, Fx.TaggedError>
---@field requestControl fun(ent: integer, opts?: { timeout?: integer }): Fx.Effect<integer, Fx.TaggedError>
---@field spawnVehicle fun(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: Fx.SpawnOptions): Fx.Effect<integer, Fx.TaggedError>
---@field spawnPed fun(model: string|integer, coords: { x: number, y: number, z: number }, heading?: number, opts?: Fx.SpawnOptions): Fx.Effect<integer, Fx.TaggedError>
---@field spawnObject fun(model: string|integer, coords: { x: number, y: number, z: number }, opts?: Fx.SpawnOptions): Fx.Effect<integer, Fx.TaggedError>

---@class Fx.Kvp
---@field KvpInvalid Fx.TaggedErrorClass
---@field KvpDecodeError Fx.TaggedErrorClass
---@field get fun(key: string, schema?: Fx.Schema): Fx.Effect<any, Fx.TaggedError>
---@field set fun(key: string, value: any, schema?: Fx.Schema): Fx.Effect<nil, Fx.TaggedError>
---@field delete fun(key: string): Fx.Effect<nil, never>
---@field keys fun(prefix: string): Fx.Effect<string[], never>
---@field typed fun(prefix: string, schema: Fx.Schema): Fx.KvpTyped

---@class Fx.KvpTyped
---@field prefix string
---@field schema Fx.Schema
local KvpTyped = {}
---@param id string
---@return Fx.Effect<any, Fx.TaggedError>
function KvpTyped:get(id) end
---@param id string
---@param value any
---@return Fx.Effect<nil, Fx.TaggedError>
function KvpTyped:set(id, value) end
---@param id string
---@return Fx.Effect<nil, never>
function KvpTyped:delete(id) end
---@return Fx.Effect<string[], never>
function KvpTyped:ids() end
---@return Fx.Effect<table<string, any>, Fx.TaggedError>
function KvpTyped:all() end

---A state bag: from Fx.state.global(), Fx.state.player(src) or Fx.state.entity(ent).
---@class Fx.StateBag
---@field name string
---@field state table

---@class Fx.StateChange
---@field bag string bag name, e.g. "player:3"
---@field value any the new value (nil when cleared)
---@field replicated boolean on the server: true when a client wrote it
---@field player? integer
---@field entity? integer

---@class Fx.StateKey
---@field name string
---@field schema Fx.Schema
local StateKey = {}
---@param bag Fx.StateBag
---@return Fx.Effect<any, Fx.TaggedError>
function StateKey:get(bag) end
---@param bag Fx.StateBag
---@param value any
---@param opts? { replicated?: boolean }
---@return Fx.Effect<nil, Fx.TaggedError>
function StateKey:set(bag, value, opts) end
---@param bag Fx.StateBag
---@param opts? { replicated?: boolean }
---@return Fx.Effect<nil, Fx.TaggedError>
function StateKey:clear(bag, opts) end
---@param handler fun(change: Fx.StateChange): Fx.Effect<any, any>|nil
---@param opts? { bag?: Fx.StateBag|string }
---@return integer cookie
function StateKey:onChange(handler, opts) end
---@param handler fun(change: Fx.StateChange): Fx.Effect<any, any>|nil
---@param opts? { bag?: Fx.StateBag|string }
---@return Fx.Effect<nil, never>
function StateKey:watch(handler, opts) end
---@param opts? { bag?: Fx.StateBag|string, buffer?: integer, strategy?: "sliding"|"dropping" }
---@return Fx.Stream<Fx.StateChange>
function StateKey:changes(opts) end
---@param bag Fx.StateBag
---@param predicate? fun(value: any): boolean
---@param opts? { timeout?: integer }
---@return Fx.Effect<any, Fx.TaggedError>
function StateKey:await(bag, predicate, opts) end

---@class Fx.State
---@field StateInvalid Fx.TaggedErrorClass
---@field StateTimeout Fx.TaggedErrorClass
---@field key fun(name: string, schema: Fx.Schema): Fx.StateKey
---@field global fun(): Fx.StateBag
---@field player fun(src?: integer): Fx.StateBag
---@field entity fun(ent: integer): Fx.StateBag

---@alias Fx.DbDone fun(result: any, err?: any)

---A Database implementation (what Fx.db.Database provides).
---@class Fx.DbDriver
---@field query? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field single? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field scalar? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field insert? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field update? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field prepare? fun(sql: string, params: table|nil, done: Fx.DbDone)
---@field transaction? fun(queries: table, params: table|nil, done: Fx.DbDone)

---@class Fx.Db
---@field SqlError Fx.TaggedErrorClass
---@field SqlDecodeError Fx.TaggedErrorClass
---@field Database Fx.Tag
---@field oxmysql Fx.DbDriver
---@field layer Fx.Layer
---@field query fun(sql: string, params?: table, opts?: { row?: Fx.Schema }): Fx.Effect<table[], Fx.TaggedError>
---@field single fun(sql: string, params?: table, opts?: { row?: Fx.Schema }): Fx.Effect<table|nil, Fx.TaggedError>
---@field scalar fun(sql: string, params?: table, opts?: { value?: Fx.Schema }): Fx.Effect<any, Fx.TaggedError>
---@field insert fun(sql: string, params?: table): Fx.Effect<integer, Fx.TaggedError>
---@field update fun(sql: string, params?: table): Fx.Effect<integer, Fx.TaggedError>
---@field prepare fun(sql: string, params?: table): Fx.Effect<any, Fx.TaggedError>
---@field transaction fun(queries: table, params?: table): Fx.Effect<boolean, Fx.TaggedError>

---@class Fx.FrameworkJob
---@field name string
---@field label? string
---@field grade? integer
---@field gradeLabel? string

---@class Fx.FrameworkPlayer
---@field source integer
---@field identifier string citizenid (QBCore/Qbox), identifier (ESX), license (standalone)
---@field name string
---@field job Fx.FrameworkJob
---@field money { cash: number, bank: number }

---@alias Fx.MoneyAccount "cash"|"bank"

---The Framework service (Fx.yield(Fx.framework.Framework)).
---@class Fx.FrameworkService
---@field name "esx"|"qbcore"|"qbox"|"standalone"
---@field getPlayer fun(src: integer): Fx.Effect<Fx.FrameworkPlayer, Fx.TaggedError>
---@field findPlayer fun(src: integer): Fx.Effect<Fx.FrameworkPlayer|nil, Fx.TaggedError>
---@field getMoney fun(src: integer, account: Fx.MoneyAccount): Fx.Effect<number, Fx.TaggedError>
---@field addMoney fun(src: integer, account: Fx.MoneyAccount, amount: number, reason?: string): Fx.Effect<number, Fx.TaggedError>
---@field removeMoney fun(src: integer, account: Fx.MoneyAccount, amount: number, reason?: string): Fx.Effect<number, Fx.TaggedError>
---@field setJob fun(src: integer, job: string, grade?: integer): Fx.Effect<Fx.FrameworkJob, Fx.TaggedError>
---@field onPlayerLoaded fun(fn: fun(src: integer): Fx.Effect<any, any>|nil): fun()
---@field onPlayerUnloaded fun(fn: fun(src: integer): Fx.Effect<any, any>|nil): fun()
---@field onJobChange fun(fn: fun(src: integer, job: Fx.FrameworkJob): Fx.Effect<any, any>|nil): fun()

---@class Fx.FrameworkModule
---@field Framework Fx.Tag
---@field PlayerNotFound Fx.TaggedErrorClass
---@field InsufficientFunds Fx.TaggedErrorClass
---@field FrameworkError Fx.TaggedErrorClass
---@field esx Fx.Layer
---@field qbcore Fx.Layer
---@field qbox Fx.Layer
---@field standalone Fx.Layer
---@field auto Fx.Layer
---@field detect fun(): "esx"|"qbcore"|"qbox"|"standalone"

---@class Fx.Nui
---@field NuiInvalidInput Fx.TaggedErrorClass
---@field NuiInvalidMessage Fx.TaggedErrorClass
---@field handle fun(name: string, spec: { input: Fx.Schema, output?: Fx.Schema }, handler: fun(input: any): any)
---@field send fun(msgType: string, payload?: any, schema?: Fx.Schema): Fx.Effect<nil, Fx.TaggedError>
---@field useFocus fun(opts?: { cursor?: boolean, keepInput?: boolean }): Fx.Effect<nil, never>

---@class Fx.Tick
---@field everyFrame fun(fn: fun()): Fx.Effect<never, never>
---@field whileNear fun(coords: { x: number, y: number, z: number }, radius: number, fn: fun(distance: number), opts?: { checkMs?: integer }): Fx.Effect<never, never>
---@field whileTrue fun(condition: (fun(): boolean), fn: fun(), opts?: { checkMs?: integer }): Fx.Effect<never, never>

---@class Fx.Compat
---@field libCallback fun(name: string, ...: any): Fx.Effect<any, Fx.TaggedError>
---@field opts fun(t: { timeout?: integer }): table

---@class Fx.CauseModule
---@field fail fun(e: any): Fx.Cause
---@field die fun(defect: any): Fx.Cause
---@field interrupt fun(fiberId?: integer): Fx.Cause
---@field failures fun(c: Fx.Cause): any[]
---@field defects fun(c: Fx.Cause): any[]
---@field failureOption fun(c: Fx.Cause): any
---@field isInterrupted fun(c: Fx.Cause): boolean
---@field isInterruptedOnly fun(c: Fx.Cause): boolean
---@field squash fun(c: Fx.Cause): any
---@field pretty fun(c: Fx.Cause): string

---@class Fx
---@field version string
---@field isServer boolean
---@field resourceName string
---@field unit Fx.Effect<nil, never>
---@field void Fx.Effect<nil, never>
---@field never Fx.Effect<never, never>
---@field yieldNow Fx.Effect<nil, never>
---@field fiberId Fx.Effect<integer, never>
---@field Cause Fx.CauseModule
---@field Schedule Fx.ScheduleModule
---@field Scope Fx.ScopeTag
---@field Layer Fx.LayerModule
---@field Runtime Fx.RuntimeModule
---@field S Fx.SchemaModule
---@field Schema Fx.SchemaModule
---@field Ref { make: fun(v: any): Fx.Effect<Fx.Ref, never>, unsafeMake: fun(v: any): Fx.Ref }
---@field Deferred { make: fun(): Fx.Effect<Fx.Deferred, never>, unsafeMake: fun(): Fx.Deferred }
---@field Semaphore { make: fun(permits: integer): Fx.Effect<Fx.Semaphore, never>, unsafeMake: fun(permits: integer): Fx.Semaphore }
---@field Queue { unsafeMake: fun(capacity?: integer, strategy?: "suspend"|"dropping"|"sliding"): Fx.Queue, unbounded: fun(): Fx.Effect<Fx.Queue, never>, bounded: fun(n: integer): Fx.Effect<Fx.Queue, never>, dropping: fun(n: integer): Fx.Effect<Fx.Queue, never>, sliding: fun(n: integer): Fx.Effect<Fx.Queue, never> }
---@field PubSub { make: fun(): Fx.Effect<Fx.PubSub, never>, unsafeMake: fun(): Fx.PubSub }
---@field Stream Fx.StreamModule
---@field trace Fx.Trace
---@field metrics Fx.Metrics
---@field currentSpan Fx.Effect<Fx.Span|nil, never>
---@field TimeoutError Fx.TaggedErrorClass
---@field NoSuchElementError Fx.TaggedErrorClass
---@field UnknownError Fx.TaggedErrorClass
---@field ParseError Fx.TaggedErrorClass
---@field resourceScope Fx.ScopeObject
---@field log Fx.Log
---@field security Fx.Security
---@field RateLimiter Fx.RateLimiterModule
---@field net Fx.Net
---@field rpc Fx.Rpc
---@field player Fx.Player
---@field config Fx.Config
---@field assets Fx.Assets
---@field entity Fx.Entity
---@field kvp Fx.Kvp
---@field state Fx.State
---@field tick Fx.Tick
---@field db Fx.Db
---@field framework Fx.FrameworkModule
---@field nui Fx.Nui
---@field compat Fx.Compat
Fx = {}

---@generic A
---@param value A
---@return Fx.Effect<A, never>
function Fx.succeed(value) end
---@generic E
---@param err E
---@return Fx.Effect<never, E>
function Fx.fail(err) end
---@return Fx.Effect<never, never>
function Fx.die(defect) end
---@param cause Fx.Cause
---@return Fx.Effect<never, any>
function Fx.failCause(cause) end
---@generic A
---@param fn fun(): A?
---@return Fx.Effect<A, never>
function Fx.sync(fn) end
---@generic A
---@param fn fun(): A?
---@param onError? fun(err: any): any
---@return Fx.Effect<A, Fx.TaggedError>
function Fx.try(fn, onError) end
---@generic A
---@param fn fun(): Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Fx.suspend(fn) end
---@param register fun(resume: fun(eff: Fx.Effect<any, any>)): (fun()|nil)
---@return Fx.Effect<any, any>
function Fx.async(register) end
---@param register fun(done: fun(ok: boolean, valueOrError: any)): (fun()|nil)
---@return Fx.Effect<any, any>
function Fx.callback(register) end
---@param ms integer
---@return Fx.Effect<nil, never>
function Fx.sleep(ms) end
---Wrap fn so each call runs in a span.
---@generic F
---@param name string
---@param fn F
---@param opts? Fx.SpanOptions
---@return F
function Fx.span(name, fn, opts) end
---@return Fx.Effect<nil, never>
function Fx.annotateCurrentSpan(key, value) end
---@param exit Fx.Exit
---@return Fx.Effect<any, any>
function Fx.fromExit(exit) end
---@generic A
---@param v A|nil
---@param onNil? fun(): any
---@return Fx.Effect<A, any>
function Fx.fromNullable(v, onNil) end
---@param p table Citizen promise
---@return Fx.Effect<any, any>
function Fx.fromPromise(p) end
---@param f fun(fiber: Fx.Fiber): Fx.Effect<any, any>
---@return Fx.Effect<any, any>
function Fx.withFiber(f) end

---The service for tag if one is provided, else nil. Never fails.
---@param tag Fx.Tag
---@return Fx.Effect<any, never>
function Fx.serviceOption(tag) end
---@param check fun(): boolean
---@param timeout integer
---@param onTimeout fun(): any
---@return Fx.Effect<nil, any>
function Fx.poll(check, timeout, onTimeout) end

---Direct-style effects: Fx.gen(function() local x = Fx.yield(eff) ... end)
---@generic A
---@param body fun(...): A?
---@return Fx.Effect<A, any>
function Fx.gen(body, ...) end
---Inside Fx.gen only.
---@generic A
---@param eff Fx.Effect<A, any>
---@return A
function Fx.yield(eff) end

---@param items any[]
---@param f fun(item: any, i: integer): Fx.Effect<any, any>
---@param opts? { concurrency?: integer|"unbounded", discard?: boolean }
---@return Fx.Effect<any[], any>
function Fx.forEach(items, f, opts) end
---@param effects Fx.Effect<any, any>[]|table<string, Fx.Effect<any, any>>
---@param opts? { concurrency?: integer|"unbounded" }
---@return Fx.Effect<table, any>
function Fx.all(effects, opts) end
---@param effects Fx.Effect<any, any>[]
---@return Fx.Effect<any, any>
function Fx.raceAll(effects) end
---@param fibers Fx.Fiber[]
---@return Fx.Effect<nil, never>
function Fx.interruptAll(fibers) end
---@param f fun(restore: fun(eff: Fx.Effect<any, any>): Fx.Effect<any, any>): Fx.Effect<any, any>
---@return Fx.Effect<any, any>
function Fx.uninterruptibleMask(f) end

---@generic A, R
---@param acquire Fx.Effect<A, any>
---@param use fun(a: A): Fx.Effect<R, any>
---@param release fun(a: A, exit: Fx.Exit): Fx.Effect<any, any>
---@return Fx.Effect<R, any>
function Fx.acquireUseRelease(acquire, use, release) end
---Requires Scope.
---@generic A
---@param acquire Fx.Effect<A, any>
---@param release fun(a: A, exit: Fx.Exit): Fx.Effect<any, any>
---@return Fx.Effect<A, any>
function Fx.acquireRelease(acquire, release) end
---@generic A
---@param eff Fx.Effect<A, any>
---@return Fx.Effect<A, any>
function Fx.scoped(eff) end
---Requires Scope.
---@param fin fun(exit: Fx.Exit): Fx.Effect<any, any>
---@return Fx.Effect<nil, never>
function Fx.addFinalizer(fin) end

---@param key string
---@return Fx.Tag
function Fx.Tag(key) end
---@param tag string
---@param fields? table<string, Fx.Schema>
---@return Fx.TaggedErrorClass
function Fx.TaggedError(tag, fields) end
---@param v any
---@return string
function Fx.inspect(v) end
---@param v any
---@return boolean
function Fx.isEffect(v) end

---@param eff Fx.Effect<any, any>
---@param opts? { onExit?: fun(exit: Fx.Exit), context?: table }
---@return Fx.Fiber
function Fx.runFork(eff, opts) end
---@param eff Fx.Effect<any, any>
---@param cb fun(exit: Fx.Exit)
---@return Fx.Fiber
function Fx.runCallback(eff, cb) end
---@generic A
---@param eff Fx.Effect<A, any>
---@return A
function Fx.runSync(eff) end
---@param eff Fx.Effect<any, any>
---@return Fx.Exit
function Fx.runSyncExit(eff) end
---Block the current Citizen thread until eff is done; raises on failure.
---@generic A
---@param eff Fx.Effect<A, any>
---@return A
function Fx.runAwait(eff) end
---@param rt Fx.Runtime
function Fx.setRuntime(rt) end
---@param fin function|Fx.Effect<any, any>
function Fx.onStop(fin) end

---@param msg string
---@param fields? table
---@return Fx.Effect<nil, never>
function Fx.logDebug(msg, fields) end
---@param msg string
---@param fields? table
---@return Fx.Effect<nil, never>
function Fx.logInfo(msg, fields) end
---@param msg string
---@param fields? table
---@return Fx.Effect<nil, never>
function Fx.logWarn(msg, fields) end
---@param msg string
---@param fields? table
---@return Fx.Effect<nil, never>
function Fx.logError(msg, fields) end
