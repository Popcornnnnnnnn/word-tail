import Foundation

public struct DomainLexiconPack: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tagline: String
    public let words: [String]

    public init(id: String, name: String, tagline: String, words: [String]) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.words = words
    }

    public static let builtInPacks: [DomainLexiconPack] = [
        builtIn("ai_quant", "AI, ML & Quant Finance", "Modeling, machine learning, and market analysis", """
        adversarial affine agglomerative algorithm alignment amortization annealing anomaly arbitrage
        autoregression autoregressive backpropagation backtesting backwardation baseline bayesian
        benchmark binomial bootstrapping branching calibrate calibration categorization classification
        classifier clustering coefficient collinearity combinatorial combinatorics computability
        conditional conjugate contango convergence convex convexity convolution convolutional correlation
        covariance curvature decomposition decorrelation denoising density derivative detokenization
        detrending dimensionality discriminant discriminative dispersion divergence drawdown eigenbasis
        eigenvalue eigenvector elasticity embedding entropy estimator exogenous exponential factorization
        featurization feedback forecasting generalization generative gradient greedy hedging hermitian
        heteroskedasticity heuristic histogram homoskedasticity hyperparameter hyperplane imbalance
        imputation inductive inference integral integration interpolation invariance jacobian kernel
        kurtosis leverage likelihood linearity liquidity logits lognormal longitudinal manifold margin
        marginal markov matricization matrix minimax minimization mixture momentum monotonicity multiclass
        multimodal multinomial multivariate neural neuron nonconvex nonparametric normalization numerical
        objective optimization orthogonal orthogonality outlier overfitting oversampling pairwise
        parameter parametric payoff penalty perceptron permutation polynomial posterior precision
        predictive pretraining probabilistic probability projection pruning quantile quantization
        quantized quantizer randomization ranking rebalance recall recurrence recurrent reduction
        regression regularization reinforcement reparameterization replication resampling residual
        reversion reward riskless robust sampling scalar sensitivity separability sigmoid singularity
        skewness smoothing softmax sparsity spectral spline stationarity stochastic stratification
        subgradient supervised symmetric tensor threshold tokenization tokenizer topology trajectory
        transformer triangulation truncation underfitting undersampling unigram unsupervised variance
        vector vectorization volatility weighting
        """),
        builtIn("systems_cloud", "Systems, Cloud & DevOps", "Infrastructure, networking, and software delivery", """
        aggregation allocation allocator anycast architecture artifact asynchronous atomicity auditability
        authentication authorization automation autoscaler availability backfill backlog backoff backplane
        backpressure bandwidth bastion batching beacon bidirectional binary bitmask blockchain bootloader
        bottleneck breakpoint broadcast buffering buildpack bytecode caching capability cascading
        certificate checksum ciphertext cluster codebase compilation compiler compression concurrency
        concurrent configuration connectivity consistency container containerization coroutine
        cryptography daemon datastore deadlock deallocation debugger debugging decapsulation declarative
        decrypt deduplication delegation demultiplexing dependency deployment deprecation deserialization
        directory discovery dispatch distributed downtime durability encapsulation encryption endpoint
        ephemeral epoch eviction executable failback failover filesystem firewall firmware forwarding
        gateway handshake hashing heartbeat hotfix hypervisor idempotency ingress integrity
        interoperability interrupt invalidation isolation journal journaling keystore kubelet kubernetes
        latency lease locking logging loopback manifest masking memory metastore microcode microkernel
        microservice middleware migration monolith monorepo multicast multiplexing mutex namespace
        networking nonblocking observability orchestration outage pagination parallelism partition
        partitioning payload persistence pipeline plaintext polling preemption provisioning proxy queuing
        reconciliation recovery recursion redundancy refactoring registry relay reliability repository
        resolver rollback rollout routing runtime sandbox scheduler scheduling segmentation semaphore
        serialization serverless serviceability sharding sidecar socket spooling staging stateless storage
        streaming subdomain subnet subprocess superuser synchronization synchronous syscall systemd
        teardown telemetry throttling throughput timeout timestamp tracing tunneling unicast upstream
        uptime userspace virtualization watchdog webhook websocket workload
        """),
        builtIn("product_exec", "Product, Design & Strategy", "Product decisions, design, and team planning", """
        accessibility acquisition adoption advocacy aesthetic agenda amplification analytics annotation
        aspiration attitudinal attribution audience awareness behavioral blueprint brainstorm branding
        briefing bundling cadence campaign catalog champion channel charter churn clarity collaboration
        commercialization commitment communication community compatibility competitive competitor
        complementarity composition compromise conceptualization concierge consensus constraint
        consultancy consumption context contextual continuity contrast conversion copyediting copywriting
        curation customer customization dashboard debrief decision deliverable demographic design
        desirability differentiation direction discoverability disruption editorial effectiveness
        efficiency elegance elicitation empowerment enablement engagement envision facilitation
        feasibility feature fidelity flagship focus framing funnel governance growth guidelines handoff
        hierarchy hypothesis ideation impact implementation incentive inclusivity incubation initiative
        innovation insight interface interview intuition iteration journey kickoff landing launch layout
        leadership learnability legibility localization loyalty marketability marketing messaging
        milestone minimalist mockup monetization motivation multimedia navigation negotiation newsletter
        onboarding operations opportunity outreach ownership partnership perception persona
        personalization pilot planning positioning practicality prioritization prioritizing procurement
        productivity progression promotion prototype prototyping qualitative readability readiness
        rebranding referral refinement reframing relevance repositioning research responsiveness retention
        retrospective roadmap rubric satisfaction scoping sequencing showcase simplicity sitemap
        sponsorship stakeholder storytelling strategy subscription substitution suitability summary survey
        sustainability synthesis targeting taxonomy teamwork testimonial theme timeline touchpoint
        traction tradeoff transformation typography unification usability validation value versatility
        viability visibility visualization walkthrough whitespace wireframe workshop
        """),
        builtIn("academic_science", "Academic & Scientific Writing", "Research methods, papers, and scientific prose", """
        abduction abscissa absorption abstract abstraction academia acoustics adjunction admissibility
        adsorption aerodynamics ambiguity anthropogenic antithesis apparatus applicability asymmetry
        attenuation axiom axiomatic background bibliographic bibliography biogeography causality caveat
        characterization chronology citation clarification coherence collation comparability comparative
        computation conclusion concordance confounder confounding congruence conjecture conservation
        corroboration counterargument counterexample criterion critique cumulative definitional
        delineation demarcation derivation desideratum dialectic dichotomy differential diffraction
        diffusion dimensional discrete dissertation distinction doctoral empirical empiricism endogenous
        epistemic epistemology equilibrium equivalence erratum ethical ethnography etymology evidential
        examination exemplification experiment experimental explanation extrapolation falsifiability
        falsification formulation fractal generalizable geochemistry geophysical gravitation harmonic
        heterogeneity homogeneity homology hydrodynamic hysteresis identification implication incidence
        inconclusive induction inferential infinitesimal interdependence interpretability interpretation
        introduction inverse investigation isotopic juxtaposition kinematics lemma limitation linguistics
        literature lithosphere manuscript measurand measurement mechanistic methodology metrology
        mineralogy moderation morphology nomenclature nondimensional novelty nuance ontology ordinate
        oscillation paleontology paradigm parallax particulate pedagogical pedagogy perimeter perturbation
        phenomenology phenomenon photometry plagiarism plausibility postdoctoral postulate precedent
        premise preprint presupposition propagation protocol quadrant quantification rationale reaction
        reactivity reconstruction refutation repeatability replicability report reproducibility retraction
        rigor salience scholarship scrutiny sedimentation sedimentology semantics significance similarity
        simulation sociological specimen spectroscopy stratigraphy subfield substantiation supplementary
        supposition symposium terminological terminology terrestrial theorem theoretical thermodynamic
        thesis transdisciplinary transmittance transposition treatise univariate variability veracity
        verification viscosity
        """),
        builtIn("finance_legal", "Finance, Accounting & Legal", "Financial reporting, accounting, contracts, and law", """
        abeyance accrual acquiescence adjournment adjudication admissible affidavit affiliation allegation
        allotment amendment annuity antitrust appellant appropriation arbitration arrears assignee
        assurance attestation attorney audit auditor bailment balance bankruptcy beneficiary bequest
        borrower breach capital capitalization cashier chattel claimant clause codicil collateral
        collusion commoditization commodity compensatory compliance concession consolidation contingency
        contract contractor contractual conveyance corporation counsel counterclaim counterparty covenant
        creditor damages debenture debit deductible deduction defendant deferral deficit delict
        delinquency demurrer deposit deposition depreciation disbursement discharge disclaimer disclosure
        discount dissolution dividend domicile easement escrow estoppel executor exemption expenditure
        expense expropriation extrajudicial factoring fiduciary foreclosure forfeiture franchise fraud
        fungibility garnishment guarantor impairment indemnification indemnity infringement inheritance
        injunction insolvency insurance interpleader intestacy invoice joinder jurisdiction jurisprudence
        leasehold ledger lessee lessor liability lienholder liquidate liquidation litigant litigation
        magistrate malfeasance misappropriation misdemeanor misfeasance misrepresentation mortgage
        negligence negotiable noncompliance notary novation obligation obligee obligor overpayment payee
        payroll pecuniary perfection petitioner plaintiff pleading premium prepayment probate proceeds
        promissory prorating prospectus provision punitive ratification rebate receivable receivership
        recoupment recourse redeemable redemption remittance replevin repossession rescission restitution
        retainage revenue royalty sanction securitization settlement severability shareholder solvency
        stipulation sublease subordination subpoena subrogation surcharge surety taxation tenancy
        testament testimony tortfeasor trademark transferee transferor treasury trespass tribunal trustee
        trustor underwriting usufruct valuation vested waiver withholding
        """),
        builtIn("medical_bio", "Medical, Clinical & Biotech", "Clinical care, anatomy, and life sciences", """
        abscess acidosis adenoma adipose adjuvant agonist albumin allele allograft alveolus analgesia
        anaphylaxis anastomosis anemia anesthesia aneurysm angiogenesis angioplasty antagonist antibiotic
        antibody anticoagulant antigen antiserum antiviral aorta apoptosis arrhythmia arthritis aseptic
        asthma auscultation autoimmune autophagy bacteremia bacteriology bacteriophage bioassay
        biochemical biofilm bioinformatics biomarker biopsy biosynthesis blastocyst bolus bradycardia
        bronchoscopy carcinoma cardiology catheter cellulitis centrosome cerebrospinal chemotherapy
        chromosome cirrhosis coagulation codon collagen colonoscopy comorbidity convalescence
        corticosteroid creatinine cryotherapy cyanosis cytokine cytology cytoplasm cytoskeleton
        debridement dehydration delirium dementia dermatitis dialysis diastolic diploid dyspnea edema
        effusion electrolyte embolism endocrinology endoscopy endothelial enzyme epidemiology epigenetics
        epinephrine epithelial erythrocyte fibrillation fibrosis fistula gastritis genomics genotype
        glioma gluconeogenesis glycogen glycolysis hematocrit hematology hemodynamic hemoglobin hemolysis
        hemorrhage hemostasis hepatitis histamine histology homeostasis hydrocephalus hyperplasia
        hypertension hypoglycemia hypoxia immunology immunotherapy infarction inflammation infusion
        inoculation insulin intubation ischemia laparoscopy leukocyte ligation lipoprotein lymphatic
        lymphoma lysosome macrophage malignant megaloblastic meiosis melanoma meningitis metabolism
        metastasis microbiome microsurgery mitosis monocyte mucosa mutagen myelin myocardium necrosis
        nephrology neuronopathy neutrophil nociception oncology organelle osteocyte osteoporosis otology
        palpation pathogen pathology pediatrics peptide perfusion pharmacology phenotype phlebotomy
        placenta platelet pneumonia prophylaxis protease proteomics pulmonary receptor respiration
        ribosome sarcoma sepsis serology sphincter stenosis synapse tachycardia teratoma thrombosis
        toxicology trachea transplant triage trophoblast vaccine vasodilation ventilator ventricle
        virology virulence
        """)
    ]

    private static func builtIn(_ id: String, _ name: String, _ tagline: String, _ vocabulary: String) -> Self {
        Self(id: id, name: name, tagline: tagline, words: vocabulary.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}

public struct CustomDomainPack: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var words: [String]
    public var updatedAt: TimeInterval

    public init(id: String, name: String, words: [String], updatedAt: TimeInterval = 0) {
        self.id = id
        self.name = name
        self.words = words
        self.updatedAt = updatedAt
    }
}

public final class DomainPackStore {
    public struct SyncShard: Codable, Equatable, Sendable {
        public var enabledPackIDs: [String]
        public var customPacks: [CustomDomainPack]
        public var updatedAt: TimeInterval

        public init(enabledPackIDs: [String] = [], customPacks: [CustomDomainPack] = [], updatedAt: TimeInterval = 0) {
            self.enabledPackIDs = enabledPackIDs
            self.customPacks = customPacks
            self.updatedAt = updatedAt
        }
    }

    public enum ImportError: LocalizedError, Equatable, Sendable {
        case fileTooLarge
        case invalidPack

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge: return "The vocabulary pack file is too large."
            case .invalidPack: return "A vocabulary pack needs a valid ID, a name, and at least one word."
            }
        }
    }

    private typealias WordIndex = [Character: [String]]

    private static let builtInIndexes: [String: WordIndex] = Dictionary(uniqueKeysWithValues:
        DomainLexiconPack.builtInPacks.map { ($0.id, index($0.words)) }
    )
    private static let maxImportBytes = 512 * 1024
    private static let maxWordsPerPack = 5_000

    private let queue = DispatchQueue(label: "app.wordtail.macos.domain-packs")
    private let directoryURL: URL
    private let configURL: URL
    private let packsURL: URL
    private var shard: SyncShard
    private var customIndexes: [String: WordIndex] = [:]
    private var enabledIndex: WordIndex = [:]

    public init(directoryURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = directoryURL ?? appSupport.appendingPathComponent("WordTail", isDirectory: true)
        self.directoryURL = directory
        configURL = directory.appendingPathComponent("domain_packs_config.json")
        packsURL = directory.appendingPathComponent("domain_packs.json")

        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: packsURL), let saved = try? decoder.decode(SyncShard.self, from: data) {
            shard = saved
        } else {
            let enabled = (try? decoder.decode([String].self, from: Data(contentsOf: configURL))) ?? []
            let custom = (try? decoder.decode([CustomDomainPack].self, from: Data(contentsOf: packsURL))) ?? []
            shard = SyncShard(enabledPackIDs: Self.cleanEnabledIDs(enabled), customPacks: custom.compactMap(Self.cleanPack))
        }
        rebuildIndexes()
    }

    public var enabledPackIDs: [String] { queue.sync { shard.enabledPackIDs } }
    public var customPacks: [CustomDomainPack] { queue.sync { shard.customPacks } }

    @discardableResult
    public func setEnabledPackIDs(_ ids: [String]) -> Bool {
        queue.sync {
            let enabled = Self.cleanEnabledIDs(ids)
            guard enabled != shard.enabledPackIDs else { return true }
            var next = shard
            next.enabledPackIDs = enabled
            next.updatedAt = max(Date().timeIntervalSince1970, shard.updatedAt.nextUp)
            return (try? save(next)) != nil
        }
    }

    /// Imported packs are included by default. An explicit override selects exactly the given pack IDs.
    public func matching(lowercasedPrefix: String, overrideEnabledPackIDs: [String]? = nil) -> [String] {
        guard let first = lowercasedPrefix.first else { return [] }
        return queue.sync {
            if let ids = overrideEnabledPackIDs {
                var seen = Set<String>()
                return ids.flatMap { id in
                    (Self.builtInIndexes[id] ?? customIndexes[id])?[first] ?? []
                }.filter { $0.hasPrefix(lowercasedPrefix) && seen.insert($0).inserted }
            }
            return enabledIndex[first, default: []].filter { $0.hasPrefix(lowercasedPrefix) }
        }
    }

    public func exportCustomPackJSON(id: String) throws -> Data {
        try queue.sync {
            guard let pack = shard.customPacks.first(where: { $0.id == id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(pack)
        }
    }

    @discardableResult
    public func importCustomPack(data: Data) throws -> CustomDomainPack {
        guard data.count <= Self.maxImportBytes else { throw ImportError.fileTooLarge }
        let decoded = try JSONDecoder().decode(CustomDomainPack.self, from: data)
        guard var pack = Self.cleanPack(decoded) else { throw ImportError.invalidPack }
        return try queue.sync {
            var next = shard
            let previous = next.customPacks.first(where: { $0.id == pack.id })?.updatedAt ?? 0
            pack.updatedAt = max(Date().timeIntervalSince1970, previous.nextUp)
            next.customPacks.removeAll { $0.id == pack.id }
            next.customPacks.append(pack)
            next.customPacks.sort { $0.id < $1.id }
            try save(next)
            return pack
        }
    }

    public func exportSyncShard() -> SyncShard { queue.sync { shard } }

    @discardableResult
    public func applyRemoteShards(_ shards: [String: SyncShard]) -> Bool {
        queue.sync {
            var next = shard
            var packs: [String: CustomDomainPack] = [:]
            for pack in next.customPacks { packs[pack.id] = pack }
            for incoming in shards.values {
                let enabled = Self.cleanEnabledIDs(incoming.enabledPackIDs)
                if incoming.updatedAt.isFinite,
                   incoming.updatedAt > next.updatedAt ||
                   (incoming.updatedAt == next.updatedAt && next.enabledPackIDs.lexicographicallyPrecedes(enabled)) {
                    next.enabledPackIDs = enabled
                    next.updatedAt = incoming.updatedAt
                }
                for rawPack in incoming.customPacks {
                    guard rawPack.updatedAt.isFinite, let pack = Self.cleanPack(rawPack) else { continue }
                    if let existing = packs[pack.id], !Self.isNewer(pack, than: existing) { continue }
                    packs[pack.id] = pack
                }
            }
            next.customPacks = packs.values.sorted { $0.id < $1.id }
            guard next != shard else { return true }
            return (try? save(next)) != nil
        }
    }

    private static func isNewer(_ incoming: CustomDomainPack, than existing: CustomDomainPack) -> Bool {
        if incoming.updatedAt != existing.updatedAt { return incoming.updatedAt > existing.updatedAt }
        if incoming.name != existing.name { return incoming.name > existing.name }
        return existing.words.lexicographicallyPrecedes(incoming.words)
    }

    private func save(_ next: SyncShard) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Commit the synced state together. The config file is a readable list of enabled built-ins.
        try encoder.encode(next).write(to: packsURL, options: .atomic)
        if next.enabledPackIDs != shard.enabledPackIDs || !FileManager.default.fileExists(atPath: configURL.path) {
            try? encoder.encode(next.enabledPackIDs).write(to: configURL, options: .atomic)
        }
        shard = next
        rebuildIndexes()
    }

    private func rebuildIndexes() {
        customIndexes = Dictionary(shard.customPacks.map { ($0.id, Self.index($0.words)) }, uniquingKeysWith: { _, last in last })
        var combined: WordIndex = [:]
        var seen = Set<String>()
        for id in shard.enabledPackIDs + shard.customPacks.map(\.id) {
            guard let index = Self.builtInIndexes[id] ?? customIndexes[id] else { continue }
            for (first, words) in index {
                combined[first, default: []] += words.filter { seen.insert($0).inserted }
            }
        }
        enabledIndex = combined
    }

    private static func index(_ words: [String]) -> WordIndex {
        var result: WordIndex = [:]
        for word in words {
            if let first = word.first { result[first, default: []].append(word) }
        }
        return result
    }

    private static func cleanEnabledIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { builtInIndexes[$0] != nil && seen.insert($0).inserted }
    }

    private static func cleanPack(_ pack: CustomDomainPack) -> CustomDomainPack? {
        let id = String(pack.id.lowercased().split { character in
            !(character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-"))
        }.joined(separator: "-").prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let name = String(pack.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !id.isEmpty, builtInIndexes[id] == nil, !name.isEmpty else { return nil }

        var words: [String] = []
        var seen = Set<String>()
        for rawWord in pack.words {
            let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (4...64).contains(word.utf8.count),
                  word.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            let lower = word.lowercased()
            if seen.insert(lower).inserted {
                words.append(lower)
                if words.count == maxWordsPerPack { break }
            }
        }
        guard !words.isEmpty else { return nil }
        return CustomDomainPack(id: id, name: name, words: words, updatedAt: pack.updatedAt)
    }
}
