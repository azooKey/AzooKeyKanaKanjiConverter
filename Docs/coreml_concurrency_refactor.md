# CoreML Concurrency Refactor Plan

This document captures a multi-session plan for making the `Zenz` / CoreML execution path fully Swift-concurrency-safe. The work is intentionally split into three sessions so we can land incremental changes without breaking existing behaviour.

## Background

Recent attempts to wrap the CoreML bridge (`ZenzCoreMLService`) in an `actor` surfaced numerous `#SendingRisksDataRace` errors. Root causes:

- `Zenz`, `ZenzContext`, `DicdataStoreState`, `Lattice`/`LatticeNode`, `EfficientNGram`, `ZenzTokenizer` etc. are not `Sendable` and often wrap mutable state or C APIs.
- The CoreML bridge currently passes rich reference types (lattice nodes, personalization models, dictionary states) directly into `Kana2Kanji` logic, so actor isolation cannot be achieved locally.
- `KanaKanjiConverter` owns caches (`lattice`, `previousInputData`, `ZenzaiCache`) that are mutated from both CPU and CoreML paths.
- The llama.cpp-based CPU pipeline continues to be the primary path. This refactor isolates CoreML calls into a “review-only module” so the two pipelines stop interfering, which also keeps the CPU route easier to maintain and optimise.
- Both CoreML and llama.cpp pipelines should share identical DTOs/interfaces. We will start with CoreML and then refactor the llama.cpp path to consume the same DTOs so the two sides stay symmetrical.

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
| `ZenzaiCache` (struct) | `ConversionAlgorithms/Zenzai/zenzai.swift` | Contains `Lattice` references. Needs redesign if we want to send across actors; otherwise keep inside CPU actor and request only primitive hints. |

### Current status (Session 1)

- ✅ Introduced DTO wrappers (`ZenzPersonalizationHandle`, `DicdataStoreStateHandle`) so we can clearly enumerate what the CoreML service is allowed to read.
- ✅ Documented `Sendable` / `@unchecked Sendable` coverage for `Lattice`/`LatticeNode`/`RegisteredNode`/`CandidateData`/`ZenzaiCache`, and simplified the old CoreML context DTOs so the converter now assembles them locally.
- ✅ Moved the CoreML conversion flow back into `KanaKanjiConverter`, preventing the service from touching `DicdataStoreState` or `ZenzaiCache` directly. The service now focuses on loading/predicting, while the CPU pipeline runs `all_zenzai` itself.
- ⚠️ `Lattice`/`LatticeNode`/`ZenzaiCache` are still confined to the main converter actor; we still need snapshot/value designs before they can cross the boundary safely.
- ⚠️ `DicdataStoreStateHandle` remains a simple reference wrapper, so we ultimately need read-only snapshots or narrow APIs.
- ⚠️ `ZenzCoreMLService` is still a class guarded by locks. Snapshot work must land before we can actor-isolate it in Session 2.

### Session 2 planning log

Session 2 focuses on making the CoreML path consume DTOs only, then reintroducing the actor-based service. Official TODOs:

- [x] Produce `ZenzPrefixConstraintSnapshot` and `ZenzCandidateSnapshot` at the `all_zenzai` call site and pass them into the CoreML bridge. _(Personalisation still relies on `ZenzPersonalizationHandle`; vector snapshots remain TODO.)_
- [x] Bundle the evaluation inputs (`convertTarget`, constraint snapshot, candidate snapshot, execution flags) into a single `ZenzEvaluationRequest` DTO so the future actor receives one value payload per review.
- [x] Update `all_zenzai` to consume async evaluator closures and convert `ZenzCoreMLService` into an actor that owns `Zenz`, so evaluation happens via DTO-only actor hops.
- [ ] Define a CoreML response DTO (`ZenzCoreMLResultSnapshot`, TBD) so the CPU pipeline ingests snapshots instead of reference types.
- [ ] Prepare the llama.cpp path to consume the same DTOs so both sides stay symmetric.
- [ ] Once the DTO API stabilises, convert `ZenzCoreMLService` back into an `actor` and delete `blockingAsync`.

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

Each DTO should conform to `Sendable` and be created inside `KanaKanjiConverter` before being passed into the CoreML actor. The response should likewise be a DTO (`ZenzCoreMLResultSnapshot`) that the CPU cache can ingest without touching shared references.

Once this structure is in place, the CoreML service can be rewritten as an actor that only accepts DTOs. The CPU cache stays confined to the main actor (`KanaKanjiConverter`), and the CoreML side transmits snapshots exclusively.

**Deliverables:** Updated type definitions with `Sendable` compliance (or TODO markers), plus unit tests covering basic Sendable conformance where practical. When wrappers (`ZenzPersonalizationHandle`, `DicdataStoreStateHandle`) are introduced, note them in this table.

## Session 2 – Actor-Isolated CoreML Service

**Goal:** Re-introduce `actor ZenzCoreMLService` now that DTOs/Sendable wrappers are in place.

Tasks:

1. **Actorise CoreML service**  
   - Make `ZenzCoreMLService` an `actor`.
   - Store the CoreML `Zenz` model, caches, tokenizer state inside the actor; expose async APIs.
2. **Async bridge from `KanaKanjiConverter`**  
   - Replace `blockingAsync` with structured async/await usage (e.g. `Task.detached` + `await` where needed).
   - Provide async entry points for `requestCandidates` (possibly with back-deployment to sync entry point).
3. **Refactor `ZenzContext` implementations**  
   - Ensure both CoreML-backed and CPU-backed contexts satisfy the actor isolation contracts (no shared mutable state leaks).
4. **Regression tests**  
   - Add tests ensuring CoreML and CPU paths produce identical results for a fixed fixture, executed under Swift concurrency runtime.

**Deliverables:** Working CoreML actor bridge, passing `swift build --traits ZenzaiCoreML` (in unrestricted environment), concurrency warnings resolved.

## Session 3 – Cache Ownership & Lifecycle

**Goal:** Harmonise cache and lifecycle management between CPU & CoreML paths.

Tasks:

1. **Centralise conversion cache**  
   - Extract `previousInputData`, `lattice`, `ZenzaiCache` etc. into a dedicated cache manager that is `Sendable`/actor-aware.
2. **Unified lifecycle hooks**  
   - Ensure `stopComposition`, `resetMemory`, and prediction APIs notify both CPU and CoreML caches consistently.
3. **Performance verification**  
   - Add benchmarks or profiling scripts to confirm no regressions in latency or memory usage.
4. **Documentation updates**  
   - Expand `Docs/ZenzAvailability.md` (and this plan) with final architecture diagrams and guidance for future contributors.

**Deliverables:** Clean separation of responsibilities, updated documentation, and automated tests/benchmarks demonstrating stability.

---

Keeping this plan up to date across sessions will help us maintain momentum and avoid re-litigating design choices. Before each session, review the checklist above and adjust scope based on the latest findings. For any cross-cutting blockers (e.g. types that cannot be made `Sendable`), note them here with rationale so future contributors understand the constraints.
