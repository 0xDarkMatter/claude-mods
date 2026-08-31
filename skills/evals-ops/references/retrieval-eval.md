# Retrieval Eval — scoring RAG without conflating two different bugs

Retrieval is the most common thing people build evals for, and the most commonly
mis-measured. The mistake is universal: score the final answer, watch it drop, and
have no idea whether the retriever failed or the generator did.

## Split the pipeline before you score it

A RAG answer passes through two stages that fail independently. Score them
separately or you cannot act on either.

|  | Retrieved the right context | Retrieved the wrong context |
|---|---|---|
| **Answer correct** | Working as intended | **Lucky** — the model knew it anyway, or guessed. Will fail when the question shifts |
| **Answer wrong** | **Generation bug** — chunking, prompt, or model | **Retrieval bug** — embeddings, index, query rewriting |

The two off-diagonal cells need opposite fixes, and end-to-end accuracy averages
them into one uninterpretable number. Worse, the top-right cell — right answer from
wrong context — scores as a *pass* end-to-end and is a latent failure exactly like
the lucky pass in `eval-taxonomy.md`.

**Minimum viable split:** for every case, record the retrieved chunk ids alongside
the answer. That single field turns an opaque score into a 2x2 you can act on.

## Retrieval metrics

Retrieval is the one place in the eval stack where **deterministic scoring
genuinely dominates** — you have ground-truth chunk ids, so no judge is required.
Take the free signal.

| Metric | Definition | Use when |
|---|---|---|
| **Recall@k** | Fraction of relevant chunks that appear in the top k | The headline. If the right chunk is not in the context, nothing downstream can save you |
| **Precision@k** | Fraction of the top k that are relevant | Context budget is tight; noise crowds out signal |
| **MRR** | Mean of 1/rank of the first relevant chunk | One right answer per query; you care that it ranks high |
| **nDCG@k** | Rank-discounted gain over graded relevance | Multiple chunks matter and some matter more |
| **Context precision** | Of the context actually passed to the model, how much was used | Diagnosing bloated prompts and cost |

**Recall@k is the one to gate on.** Precision failures degrade an answer; recall
failures make a correct answer impossible. Measure recall at the k you actually
retrieve *and* at a larger k — if recall@20 is high while recall@5 is poor, you
have a ranking problem, not an embedding problem, and those are different fixes.

## Building the ground truth

The dataset is the hard part, as always (`golden-datasets.md`). What retrieval
adds:

- **Annotate chunk ids, not passages.** Ids survive re-chunking; quoted text does
  not. Store the chunk's stable id plus a content hash so a silent re-index shows
  up as drift rather than as a mysterious recall drop.
- **Relevance is graded, not binary,** for anything but the simplest corpus:
  `2` = answers the question, `1` = useful context, `0` = irrelevant. nDCG needs
  this; recall@k works fine treating >= 1 as relevant.
- **Multiple relevant chunks are normal.** A question answerable only by combining
  two documents is a different (harder) test than a single-hop lookup — label the
  hop count and report the two classes separately.
- **Harvest queries from real traffic.** Synthetic questions generated *from* a
  chunk are trivially retrievable from that chunk — they share its vocabulary. They
  measure your embedding model's ability to match paraphrases, not your retriever's
  ability to handle how people actually ask.

That last point is the single most common way a retrieval eval flatters itself.
A set of "generate a question from this passage" pairs will show recall@5 above
0.95 on a system that fails constantly in production.

## Failure classes worth their own bucket

Each of these fails differently and needs its own cases:

| Class | Why it breaks |
|---|---|
| **Vocabulary mismatch** | User says "can't log in", docs say "authentication failure". Pure semantic search handles this; keyword search does not — and hybrid exists for the reverse case |
| **Exact identifiers** | Order numbers, error codes, SKUs, function names. Embeddings are *bad* at these; this is what BM25/keyword hybrid is for |
| **Multi-hop** | The answer needs two documents. Single-shot retrieval structurally cannot |
| **Negation / absence** | "Which plans do NOT include support?" Similarity retrieves the plans that *do* |
| **Temporal** | "The current policy" retrieves a superseded version that is textually similar. Needs metadata filtering, not better embeddings |
| **Nothing relevant exists** | The corpus does not contain the answer. Correct behaviour is to say so — and it must be a scored case, or the system learns to always answer |

The last one deserves emphasis: **a golden set with no unanswerable questions
cannot detect hallucination under retrieval failure**, which is the exact scenario
users hit most often.

## Generation-side metrics

Once the right context is in hand:

| Metric | Question | Evaluator |
|---|---|---|
| **Faithfulness / groundedness** | Is every claim supported by the retrieved context? | Judge (`llm-judge.md`) — decompose into claims, check each |
| **Citation accuracy** | Do the cited chunk ids actually contain the cited content? | **Deterministic** — verify the id exists and the claim maps to it |
| **Answer relevance** | Does it address the question asked? | Judge |
| **Refusal correctness** | Does it decline when the context does not contain the answer? | Deterministic, on the unanswerable bucket |

Citation accuracy is quietly one of the highest-value checks available: it is free,
it needs no judge, and it catches the specific failure where a model produces a
confident answer and attaches a plausible-but-unrelated source.

## What to gate

| Tier | Check |
|---|---|
| **Blocking** | recall@k on the frozen query set; citation-id validity; refusal rate on the unanswerable bucket |
| **Blocking (ceiling)** | Context tokens per query — retrieval regressions often show up as cost before they show up as accuracy |
| **Advisory until calibrated** | Faithfulness and answer-relevance judges |
| **Diagnostic** | The 2x2 above, per bucket — this is what tells you which team owns the drop |

## Cross-reference

- The levels this sits inside: `eval-taxonomy.md`
- Case construction and freeze discipline: `golden-datasets.md`
- Grading faithfulness without fooling yourself: `llm-judge.md`
- Where these land in CI: `regression-gating.md`
