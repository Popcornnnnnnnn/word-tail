import Foundation

public enum TechLexicon {
    /// Curated English software engineering, AI, and quantitative vocabulary often absent from or ranked low in stock dictionaries.
    public static let words: [String] = [
        "algorithm", "algorithms", "algorithmic",
        "anthropic", "antigravity",
        "architecture", "architectural", "asynchronous", "asynchronously",
        "authentication", "authorization", "autocomplete", "automation",
        "backtesting", "bandwidth", "benchmark", "benchmarking", "benchmarks",
        "bottleneck", "bottlenecks",
        "calibration", "checkpoint", "checkpoints", "chromium", "cloudflare",
        "codebase", "compilation", "compiler", "concurrency", "concurrent",
        "configuration", "configurations", "containerization", "cryptocurrency", "cryptography",
        "dashboard", "database", "databases", "debugging", "declarative",
        "decompile", "decouple", "deduplicate", "deduplication",
        "dependency", "dependencies", "deployment", "deployments",
        "deprecation", "deprecated", "deserialization", "deterministic",
        "diagnostics", "dockerfile", "documentation", "downstream",
        "ecosystem", "embedding", "embeddings", "encapsulation", "encryption",
        "endpoint", "endpoints", "environment", "environments", "ephemeral",
        "evaluation", "evaluations", "executable",
        "framework", "frameworks", "frontend",
        "granularity", "heuristic", "heuristics", "homomorphic", "hyperparameter", "hyperparameters",
        "idempotent", "idempotency", "implementation", "implementations",
        "inference", "infrastructure", "initialization", "instrumentation", "integration", "integrations",
        "interpolation", "interoperability", "invariant", "invariants", "iteration", "iterations",
        "javascript",
        "kubernetes",
        "langchain", "latency", "lightweight", "linearization", "localization",
        "markdown", "metadata", "microservice", "microservices", "middleware",
        "migration", "migrations", "minimalist", "mitigation", "modular", "monorepo", "multimodal", "multithreading",
        "namespace", "namespaces", "nonblocking", "normalization",
        "observability", "orchestration", "optimization", "optimizations", "overfitting",
        "pagination", "parallelism", "parameter", "parameters", "parameterized",
        "performance", "persistence", "persistent", "pipeline", "pipelines",
        "polymorphism", "postgresql", "postprocessing", "preprocessing", "probabilistic", "production", "profiling", "programmatic", "pytorch",
        "quantization", "quantized", "quantitative", "quantitatively",
        "refactoring", "regression", "regressions", "reinforcement", "reliability",
        "reproducible", "reproducibility", "repository", "repositories", "resilience", "retrospective",
        "sandbox", "sandboxing", "scalability", "scalable", "scheduler", "schema", "schemas",
        "semantic", "semantics", "serialization", "serverless", "simulation", "simulations",
        "specification", "specifications", "stochastic", "stylesheet", "subagent", "subagents", "subprocess", "subpixel", "supabase", "synchronous", "synchronization", "synthesize",
        "tailscale", "tailwind", "telemetry", "template", "templates", "tensorflow", "throughput",
        "tokenization", "tokenizer", "transaction", "transactions", "transformer", "transformers", "transpiler", "troubleshooting", "typescript",
        "underfitting", "upstream", "utilization",
        "validation", "vectorization", "verification", "virtualization", "visualization", "volatility", "vulnerability", "vulnerabilities",
        "webhook", "webhooks", "websocket", "websockets", "wireguard", "workflow", "workflows", "workspace", "worktree", "worktrees"
    ]

    public static let wordSet: Set<String> = Set(words)

    /// Pre-indexed by first lowercase ASCII character for O(1) bucket lookup on every keystroke.
    public static let wordsByFirstChar: [Character: [String]] = Dictionary(grouping: words) { $0.first! }

    public static func matching(lowercasedPrefix: String) -> [String] {
        guard let first = lowercasedPrefix.first,
              let bucket = wordsByFirstChar[first] else {
            return []
        }
        return bucket.filter { $0.hasPrefix(lowercasedPrefix) }
    }
}
