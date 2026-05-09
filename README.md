# Milestone 3 — Graph Machine Learning Pipeline

**CS343 Graph Data Science — Spring 2026**
**Team:** Muhammad Ammar Maqdoom, Ali Anwar
**Dataset:** Football Transfers (2017/2018)

---

## Overview

This milestone implements **two graph-based ML tasks** on the football transfer
graph following a hybrid approach:

1. **Neo4j** for graph feature engineering (Louvain communities, PageRank, FastRP embeddings)
2. **Python + scikit-learn** for the actual ML training and evaluation

### Tasks

| Task | File | Goal |
|------|------|------|
| Node Classification | `M3_phase2_node_classification.ipynb` | Predict if a club is a HighBuyer (1) or LowBuyer (0) |
| Link Prediction     | `M3_phase3_link_prediction.ipynb`     | Predict potential `SOLD_TO` links between clubs |

---

## File Structure

```
gds-project/
├── football_transfers_M2_final_5.cypher       # Milestone 2 — data loader
├── M3_phase1_feature_engineering.cypher       # Phase 1 — graph features in Neo4j
├── M3_phase2_node_classification.ipynb        # Phase 2 — node classification (Python)
├── M3_phase3_link_prediction.ipynb            # Phase 3 — link prediction (Python)
├── football_transfers_M3_pipeline.cypher      # earlier pure-Cypher attempt (kept for reference)
├── requirements.txt                           # Python dependencies
└── README_M3.md                               # this file
```

---

## Setup

### 1. Neo4j

- Make sure your local Neo4j Desktop database is running.
- Confirm Bolt URL: `bolt://localhost:7687`
- Update password in the notebooks if not `pleaseletmein` (look for `PASSWORD = "..."`).
- Confirm GDS plugin is installed: `RETURN gds.version();`

### 2. Python environment

```bash
# from the project folder
python -m venv .venv
.\.venv\Scripts\activate            # Windows PowerShell
pip install -r requirements.txt
```

### 3. Launch Jupyter

```bash
jupyter notebook
```

Open the two notebooks in the browser.

---

## Run Order

Run each step **in order**:

1. **Milestone 2 loader** — `football_transfers_M2_final_5.cypher`
   - Loads players, clubs, transfers, etc.
   - Required only once.

2. **Phase 1 feature engineering** — `M3_phase1_feature_engineering.cypher`
   - Run the file end-to-end in Neo4j Browser.
   - Builds `SOLD_TO` edges, transactional features, label, and writes Louvain `community`, `pagerank`, FastRP `embedding`.

3. **Phase 2 node classification** — `M3_phase2_node_classification.ipynb`
   - Run all cells top to bottom.
   - Outputs: classification reports, confusion matrices, model comparison, feature importance.

4. **Phase 3 link prediction** — `M3_phase3_link_prediction.ipynb`
   - Run all cells top to bottom.
   - Outputs: classification report, confusion matrix, feature importance, top-K link recommendations.

---

## Methodology Summary

### Phase 1 — Graph Feature Engineering (Cypher / GDS)

- **`SOLD_TO`** relations: `(seller:Club)-[:SOLD_TO {deals, totalFee, avgFee}]->(buyer:Club)`
- **Transactional features**: `buyCount`, `sellCount`, `avgBuyFee`, `avgSellFee`, `crossBorderBuyRatio`
- **Label**: `buyerClass` = 1 if `buyCount` ≥ 75th percentile, else 0
- **GDS algorithms** applied to a Club projection:
  - Louvain → `community`
  - PageRank → `pagerank`
  - FastRP → `embedding` (64-dim vector)

### Phase 2 — Node Classification (Python / scikit-learn)

- Pulls features and label into pandas
- Train/test split: 80/20 stratified
- Models: Random Forest, Random Forest (balanced), Logistic Regression, XGBoost
- Metrics: `classification_report`, `confusion_matrix`, accuracy
- Reports: model comparison and feature importance

### Phase 3 — Link Prediction (Python / scikit-learn — course-style)

- Holds out 10% of `SOLD_TO` edges as positives (`TEST_TRAIN`)
- Uses 90% as feature graph (`FEATURE_REL`)
- Samples ~equal number of negative pairs (`NEGATIVE_TEST_TRAIN`)
- Computes 5 classical link-prediction features in Cypher:
  - `networkDistance`
  - `preferentialAttachment`
  - `commonNeighbors`
  - `adamicAdar`
  - `clusteringCoefficient`
- Trains Random Forest in scikit-learn
- Outputs: classification report, confusion matrix, feature importance, top-K predicted links

---

## Notes

- Earlier we attempted the GDS `linkPrediction` and `nodeClassification` pipelines directly in Cypher, but ran into version-specific procedure errors. The hybrid approach used here is more portable across GDS versions and matches the course lecture material on link prediction.
- The notebooks are self-contained — running them does not modify the loaded data, only adds helper relationships (`FEATURE_REL`, `TEST_TRAIN`, `NEGATIVE_TEST_TRAIN`) which are reset on every run of Phase 3.
