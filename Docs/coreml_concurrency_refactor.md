# CoreML Concurrency Refactor Plan

This document captures a multi-session plan for making the `Zenz` / CoreML execution path fully Swift-concurrency-safe. The work is intentionally split into three sessions so we can land incremental changes without breaking existing behaviour.

## Background

Recent attempts to wrap the CoreML bridge (`ZenzCoreMLService`) in an `actor` surfaced numerous `#SendingRisksDataRace` errors. Root causes:

- `Zenz`, `ZenzContext`, `DicdataStoreState`, `Lattice`/`LatticeNode`, `EfficientNGram`, `ZenzTokenizer` etc. are not `Sendable` and often wrap mutable state or C APIs.
- The CoreML bridge currently passes rich reference types (lattice nodes, personalization models, dictionary states) directly into `Kana2Kanji` logic, so actor isolation cannot be achieved locally.
- `KanaKanjiConverter` owns caches (`lattice`, `previousInputData`, `ZenzaiCache`) that are mutated from both the llama.cpp/ZenzaiCPU side and the CoreML path.
- The llama.cpp path (typically GPU-accelerated; `ZenzaiCPU` is the literal CPU evaluator) continues to be the primary route. This refactor isolates CoreML calls into a “review-only module” so the two pipelines stop interfering, which also keeps the non-CoreML route easier to maintain and optimise.
- Both CoreML and llama.cpp pipelines should share identical DTOs/interfaces so DTO schemas stay in lockstep, but CoreML failures will continue to propagate instead of falling back to llama.cpp. We will start with CoreML and then refactor the llama.cpp path to consume the same DTOs so the two sides stay symmetrical.

Because of the breadth of the required changes, we will proceed in three well-defined sessions.

## Session 1 – Data Model Audit & Sendable Wrappers

**Goal:** Identify and wrap all non-Sendable types that will cross the CoreML actor boundary.

Tasks:

1. **Inventory mutable/shared types**  
   - `Lattice`, `LatticeNode`, `RegisteredNode`, `DicdataStoreState`, `EfficientNGram`, `ZenzTokenizer`, `CandidateData`, `ZenzaiCache`.
2. **Introduce value or wrapper types where feasible**  
   - For structs (e.g. `Lattice`) evaluate if they can adopt `Sendable` via value semantics or `@unchecked Sendable`.
   - For classes that must remain reference types, document their threading guarantees and add lightweight locks if necessary.
3. **Define DTOs for actor communication**  
   - Example: `ZenzCoreMLRequestPayload` containing only primitive/value types (tokens, raw UTF-8, personalization coefficients) instead of handing entire `DicdataStoreState` or `EfficientNGram`.
4. **Update docstrings & comments**  
   - Record which objects are allowed to be shared across actors, and which must stay inside the main converter.

### Audit Findings (Session 1)

| Type | Location | Notes / Required action |
| ---- | -------- | ----------------------- |
| `Lattice` (struct) | `ConversionAlgorithms/Lattice.swift` | Struct holds `[LatticeNodeArray]` which references `LatticeNode` objects; not trivially `Sendable`. Need value-copy or snapshot representation for cross-actor use. |
| `LatticeNode` (class) | `ConversionAlgorithms/LatticeNode.swift` | Reference type with mutable `prevs` & `values`. Requires either confinement to main actor or immutable snapshot when sharing. |
| `RegisteredNode` (struct wrapping references) | `ConversionAlgorithms/Lattice/LatticeNodeArray.swift` | Contains references to `LatticeNode`. Same constraints as above. |
| `DicdataStoreState` (class) | `DictionaryManagement/DicdataStoreState.swift` | Manages user dictionaries/memory, holds mutable arrays and LOUDS caches. Must stay on main converter actor; provide read-only DTO (e.g. `DicdataStateSnapshot`) when needed. |
| `EfficientNGram` (struct) | `Sources/EfficientNGram` | Wraps tokenizer pointer, not `Sendable`. Session 1 introduces `ZenzPersonalizationHandle` (`@unchecked Sendable`) as an interim wrapper; long-term plan is to precompute primitive personalization data. |
| `ZenzTokenizer` (struct) | `Sources/EfficientNGram/Tokenizer.swift` | Holds `any Tokenizer`; not Sendable. CoreML context should own its tokenizer entirely. |
| `Zenz` / `ZenzContext` (classes) | `ConversionAlgorithms/Zenzai/Zenz` | Provide actor-isolated wrapper; no sharing outside service. |
| `ZenzaiCache` (struct) | `ConversionAlgorithms/Zenzai/zenzai.swift` | Contains `Lattice` references. Needs redesign if we want to send across actors; otherwise keep inside the converter actor (llama.cpp/ZenzaiCPU path) and request only primitive hints. |

### Current status (Session 1)

- ✅ Introduced DTO wrappers (`ZenzPersonalizationHandle`, `DicdataStoreStateHandle`) so we can clearly enumerate what the CoreML service is allowed to read.
- ✅ Documented `Sendable` / `@unchecked Sendable` coverage for `Lattice`/`LatticeNode`/`RegisteredNode`/`CandidateData`/`ZenzaiCache`, and simplified the old CoreML context DTOs so the converter now assembles them locally.
- ✅ Moved the CoreML conversion flow back into `KanaKanjiConverter`, preventing the service from touching `DicdataStoreState` or `ZenzaiCache` directly. The service now focuses on loading/predicting, while the llama.cpp/ZenzaiCPU pipeline runs `all_zenzai` itself.
- ✅ `KanaKanjiConverter` is explicitly `@MainActor`, so the CoreML actor talks to it via the main-actor boundary instead of relying on `@unchecked Sendable`.
- ⚠️ `Lattice`/`LatticeNode`/`ZenzaiCache` are still confined to the main converter actor; we still need snapshot/value designs before they can cross the boundary safely.
- ⚠️ `DicdataStoreStateHandle` remains a simple reference wrapper, so we ultimately need read-only snapshots or narrow APIs.
- ⚠️ `ZenzCoreMLService` is still a class guarded by locks. Snapshot work must land before we can actor-isolate it in Session 2.

### Session 2 planning log

Session 2 focuses on making the CoreML path consume DTOs only, then reintroducing the actor-based service. Official TODOs:

- [x] Produce `ZenzPrefixConstraintSnapshot` and `ZenzCandidateSnapshot` at the `all_zenzai` call site and pass them into the CoreML bridge. _(Personalisation still relies on `ZenzPersonalizationHandle`; vector snapshots remain TODO.)_
- [x] Bundle the evaluation inputs (`convertTarget`, constraint snapshot, candidate snapshot, execution flags) into a single `ZenzEvaluationRequest` DTO so the future actor receives one value payload per review.
- [x] Update `all_zenzai` to consume async evaluator closures and convert `ZenzCoreMLService` into an actor that owns `Zenz`, so evaluation happens via DTO-only actor hops.
- [x] Define a CoreML response DTO (`ZenzCoreMLResultSnapshot`) so the llama.cpp/ZenzaiCPU pipeline ingests snapshots instead of reference types. *(Snapshot now contains optional best candidate, alternative constraints, lattice snapshot, and cache snapshot, and `Kana2Kanji.all_zenzai` returns it alongside existing tuple data. `KanaKanjiConverter` stores the latest snapshot for upcoming actor handoff.)*
- [x] Start consuming the response snapshot on the converter actor by rebuilding the CoreML cache from `ZenzaiCacheSnapshot`, so we can eventually remove direct cache references from the CoreML actor boundary.
- [x] Introduce `ZenzCoreMLExecutionRequest` (input data + cache/previous-input snapshots) and route `convertToLattice` through the CoreML actor so `ZenzCoreMLService` now owns the full `all_zenzai` loop (still returning concrete lattices until snapshot restoration covers prev-chains).
- [x] Add `DicdataStoreStateSnapshot` support (including `LearningManager` snapshots) so `ZenzCoreMLExecutionRequest` carries immutable dictionary state copies rather than sharing live references.
- [x] Prepare the llama.cpp path to consume the same DTOs so both sides stay symmetric. *(When `Zenzai`/`ZenzaiCPU` traits are enabled, `convertToLattice` now builds `ZenzCoreMLExecutionRequest` and runs `all_zenzai` via the locally loaded `Zenz` evaluator, updating caches/snapshots just like the CoreML actor.)*
- [x] Once the DTO API stabilises, convert `ZenzCoreMLService` back into an `actor`-first API and delete `blockingAsync`. *(Public APIs now expose async variants; the legacy sync method is a thin wrapper that still uses `blockingAsync` for compatibility until we can release a breaking change.)*

Update this list after every milestone so the next session has accurate context.

### Minimal CoreML payload (planned)

The CoreML runtime only needs the following data. Lattice construction and dictionary lookups stay inside `KanaKanjiConverter`; the CoreML service should accept only these DTOs:

1. **Input/context strings**  
   - `convertTarget` (katakana string)  
   - Prompt tokens derived from `leftSideContext` / `versionDependentConfig`
2. **Constraints**  
   - `ZenzPrefixConstraintSnapshot`, which dumps a `PrefixConstraint` into UTF-8 bytes
3. **Candidate snapshots**  
   - `ZenzCandidateSnapshot` filtered down to only the necessary fields (text, value, metadata flags, etc.), produced inside `all_zenzai` before handing to the CoreML actor.
4. **Personalisation vector**  
   - `ZenzPersonalizationVector` extracted from `EfficientNGram` (e.g. `[Float]` or `UnsafeBufferPointer<Float>`). The current `ZenzPersonalizationHandle` is temporary.
5. **Execution parameters**  
   - Scalars controlling the model: `inferenceLimit`, `requestRichCandidates`, `ZenzaiVersionDependentMode`, etc.

#### Proposal: DTO definitions

- `struct ZenzPrefixConstraintSnapshot { var utf8: [UInt8]; var hasEOS: Bool }`
- `struct ZenzCandidateSnapshot { var text: String; var value: PValue; var metadataFlags: UInt8; var nodes: [ZenzClauseSnapshot] }`
- `struct ZenzClauseSnapshot { var ruby: String; var word: String; var isLearned: Bool }`
- `struct ZenzPersonalizationVector { var alpha: Float; var baseLogProb: [Float]; var personalLogProb: [Float] }`
- `struct ZenzCoreMLExecutionConfig { var inferenceLimit: Int; var requestRichCandidates: Bool; var versionConfig: ConvertRequestOptions.ZenzaiVersionDependentMode }`

Each DTO should conform to `Sendable` and be created inside `KanaKanjiConverter` before being passed into the CoreML actor. The response should likewise be a DTO (`ZenzCoreMLResultSnapshot`) that the llama.cpp/ZenzaiCPU cache can ingest without touching shared references.

Once this structure is in place, the CoreML service can be rewritten as an actor that only accepts DTOs. The non-CoreML cache stays confined to the main actor (`KanaKanjiConverter`), and the CoreML side transmits snapshots exclusively.

**Deliverables:** Updated type definitions with `Sendable` compliance (or TODO markers), plus unit tests covering basic Sendable conformance where practical. When wrappers (`ZenzPersonalizationHandle`, `DicdataStoreStateHandle`) are introduced, note them in this table.

## Session 2 – Actor-Isolated CoreML Service

**Goal:** Re-introduce `actor ZenzCoreMLService` now that DTOs/Sendable wrappers are in place, and drive the converter APIs fully async.

Tasks:

1. **Actorise CoreML service**  
   - Make `ZenzCoreMLService` an `actor`.
   - Store the CoreML `Zenz` model, caches, tokenizer state inside the actor; expose async APIs.
2. **Async bridge from `KanaKanjiConverter`**  
   - Replace `blockingAsync` with structured async/await usage (e.g. `Task.detached` + `await` where needed).
   - Provide async entry points for `requestCandidates` (possibly with back-deployment to sync entry point).
3. **Refactor `ZenzContext` implementations**  
   - Ensure both CoreML-backed and llama.cpp/ZenzaiCPU contexts satisfy the actor isolation contracts (no shared mutable state leaks).
4. **Regression tests**  
   - Add tests ensuring CoreML and llama.cpp/ZenzaiCPU paths produce identical results for a fixed fixture, executed under Swift concurrency runtime.

**Deliverables:** Working CoreML actor bridge, passing `swift build --traits ZenzaiCoreML` (in unrestricted environment), concurrency warnings resolved.

## Session 3 – Cache Ownership & Lifecycle

**Goal:** Harmonise cache and lifecycle management between llama.cpp/ZenzaiCPU & CoreML paths.

Tasks:

1. **Centralise conversion cache**  
   - Extract `previousInputData`, `lattice`, `ZenzaiCache` etc. into a dedicated cache manager that is `Sendable`/actor-aware.  
   > Status: `KanaKanjiConverter` now stores all mutating state inside `ConversionCache` (previous input, lattice, completed/last data, CoreML cache snapshots), so the CoreML and llama.cpp/ZenzaiCPU paths share one value-type cache entry point.
2. **Unified lifecycle hooks**  
   - Ensure `stopComposition`, `resetMemory`, and prediction APIs notify both CoreML and llama.cpp/ZenzaiCPU caches consistently.  
   > Status: `ConversionCache` now encapsulates previous input/lattice/last data along with CoreML cache snapshots. `stopComposition` and `resetMemory` call `cache.resetForNewSession()` (and `resetMemory` also stops the CoreML actor), while prediction APIs (`predictNextCharacter`, post-composition predictions) invalidate Zenz caches so both CoreML and llama.cpp/ZenzaiCPU stay in sync.
3. **Actor isolation follow-up**  
   - Remove the temporary `@unchecked Sendable` on `KanaKanjiConverter` by introducing a proper conversion actor façade or message-passing boundary that the CoreML service talks to.  
   > Status: `KanaKanjiConverter` is now `@MainActor`, so the CoreML actor interacts with it through structured `await` calls instead of sharing unchecked state.
4. **Performance verification**  
   - Add benchmarks or profiling scripts to confirm no regressions in latency or memory usage.
5. **Documentation updates**  
   - Expand `Docs/ZenzAvailability.md` (and this plan) with final architecture diagrams and guidance for future contributors.

### Follow-up plan for remaining gaps

> Prerequisite: Before starting step 1, `ZenzCoreMLService` must be able to request/return DTOs via the new actor interface. In other words, the conversion actor needs to exist (even as a stub) so snapshots have a producer/consumer path.

To finish Session 2 and unblock Session 3, we need the following multi-step plan:

1. **Finalize DTO boundaries** *(decision: adopt the DTO-centric design)*  
   1.1 Define request structs (prefix/candidate snapshots, `ZenzPersonalizationVectorConfig`).  
   1.2 Extend `ZenzEvaluationRequest` so the CoreML actor owns prompt/tokenizer state entirely.  
   1.3 Design `ZenzCoreMLResultSnapshot` for candidate review outputs + lattice hints.  
   1.4 Draft `LatticeSnapshot`/`ZenzaiCacheSnapshot` formats for round-tripping.
   > Status: DTO structs (`ZenzPersonalizationVectorConfig`, `ZenzCoreMLResultSnapshot`, `LatticeSnapshot`, `ZenzaiCacheSnapshot`, `ZenzCoreMLExecutionRequest`) now live in `ZenzSnapshots.swift`; cache/lattice snapshots support `snapshot()`/`init(snapshot:)` round-trips and the request carries optional previous-input data for future use.
2. **Move `all_zenzai` behind an actor** *(decision: CoreML actor owns the full review loop)*  
   2.1 Extend `ZenzCoreMLService` so it performs candidate generation, cache/lattice building, and the entire review loop internally (main actor only sends DTOs/receives snapshots).  
   2.2 Keep model loading/prompt/tokenizer/personalization inside the same actor (no shared mutable state).  
   2.3 Provide the actor with read-only dictionary access (snapshot/API) so no `DicdataStoreState` references leak.  
   2.4 Document cache coherency rules when CoreML vs llama.cpp/ZenzaiCPU history sharing, and treat the actor’s cache as authoritative for CoreML runs.
   > Status: `ZenzCoreMLService` now accepts `ZenzCoreMLExecutionRequest`, rebuilds caches from snapshots, and invokes `all_zenzai` internally. The llama.cpp/ZenzaiCPU path also consumes the same request DTO and evaluator flow; remaining work is limited to full async actor migration once DTO contracts settle.
3. **Snapshot non-CoreML structures** *(decision: actor-only caches with DTO round-trips)*  
   3.1 Implement builders/restorers for `LatticeSnapshot`, `ZenzaiCacheSnapshot`, `previousInputData` snapshots.  
   3.2 Rebuild caches on the main actor from snapshots returned by CoreML.  
   3.3 Lock down snapshot schemas with tests; monitor serialization overhead.  
   > Detail: Lattice snapshots should encode range/text/value/flags per node; `ZenzaiCacheSnapshot` should carry `ComposingText`, `ZenzPrefixConstraintSnapshot`, and an optional candidate snapshot. Add `snapshot()/init(snapshot:)` helpers to `Lattice`/`ZenzaiCache`.
4. **Async API conversion** *(decision: public API becomes async/await with sync wrappers)*  
   4.1 Introduce async `requestCandidates` and keep a compatibility wrapper (sync API becomes a thin wrapper around async).  
   4.2 Ensure state (`previousInputData`, `lattice`, `dicdataStoreState`) respects actor isolation.  
   4.3 Publish migration guidance for embedders/CLI (document new async API, deprecate sync API with wrapper).  
   4.4 Remove `blockingAsync` once async APIs are in place and all call sites await the actor directly.
5. **Validate & document** *(decision: regression tests + migration docs required)*  
   5.1 Add integration tests comparing llama.cpp/ZenzaiCPU vs CoreML snapshot outputs.  
   5.2 Add performance benchmarks to monitor latency/memory.  
   5.3 Update documentation with actor diagrams and async API instructions.  
   5.4 Publish migration notes for downstream users.

**Deliverables:** Clean separation of responsibilities, updated documentation, and automated tests/benchmarks demonstrating stability.

---

Keeping this plan up to date across sessions will help us maintain momentum and avoid re-litigating design choices. Before each session, review the checklist above and adjust scope based on the latest findings. For any cross-cutting blockers (e.g. types that cannot be made `Sendable`), note them here with rationale so future contributors understand the constraints.
