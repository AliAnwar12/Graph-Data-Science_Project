// ============================================================
// CS343 Graph Data Science - Spring 2026
// Milestone 3 — Phase 1: Graph Feature Engineering (Neo4j)
// Dataset: Football Transfers (2017/2018)
// Team: Muhammad Ammar Maqdoom, Ali Anwar
// ============================================================
//
// PURPOSE:
// Compute graph-derived node properties on Club nodes that
// will be used by the Python ML notebooks (Phase 2 & 3):
//   - community  (Louvain)
//   - pagerank
//   - embedding  (FastRP)
// Plus transactional features (buyCount, avgBuyFee, etc.)
// and the supervised label `buyerClass`.
//
// RUN ORDER:
// 1. Run Milestone 2 loader first (data must be in Neo4j).
// 2. Run this Phase 1 file end-to-end in Neo4j Browser.
// 3. Then run M3_phase2_node_classification.ipynb in Python.
// 4. Then run M3_phase3_link_prediction.ipynb in Python.
// ============================================================


// ============================================================
// SECTION 0: CLEANUP (safe on reruns)
// ============================================================

CALL gds.graph.drop('club-ml-graph', false);
CALL gds.graph.drop('club-lp-graph', false);

MATCH (c:Club)
REMOVE c.buyCount, c.sellCount, c.totalActivity,
       c.avgBuyFee, c.avgSellFee, c.crossBorderBuyRatio,
       c.buyerClass, c.mlSplit,
       c.predBuyerClass, c.distToClass1, c.distToClass0,
       c.community, c.pagerank, c.embedding;

MATCH ()-[r:SOLD_TO]->() DELETE r;
MATCH ()-[r:FEATURE_REL]->() DELETE r;
MATCH ()-[r:TEST_TRAIN]->() DELETE r;
MATCH ()-[r:NEGATIVE_TEST_TRAIN]->() DELETE r;


// ============================================================
// SECTION 1: BUILD CLUB-TO-CLUB SOLD_TO EDGES
// ============================================================
//
// (seller:Club)-[:SOLD_TO {deals, totalFee, avgFee}]->(buyer:Club)
// This club-to-club relation is the basis for graph ML.
// ============================================================

MATCH (seller:Club)<-[:FROM_CLUB]-(t:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
WITH seller, buyer,
     count(t) AS deals,
     sum(coalesce(t.feeNumeric, 0.0)) AS totalFee
MERGE (seller)-[r:SOLD_TO]->(buyer)
SET r.deals = deals,
    r.totalFee = totalFee,
    r.avgFee = CASE WHEN deals = 0 THEN 0.0 ELSE totalFee / toFloat(deals) END;

MATCH ()-[r:SOLD_TO]->()
RETURN count(r) AS SoldToEdges;


// ============================================================
// SECTION 2: TRANSACTIONAL FEATURES ON CLUB NODES
// ============================================================

MATCH (c:Club)
SET c.crossBorderBuyRatio = 0.0;

MATCH (c:Club)
OPTIONAL MATCH (tIn:Transfer)-[:TO_CLUB]->(c)
WITH c, count(tIn) AS buyCount, coalesce(avg(tIn.feeNumeric), 0.0) AS avgBuyFee
OPTIONAL MATCH (tOut:Transfer)-[:FROM_CLUB]->(c)
WITH c, buyCount, avgBuyFee,
     count(tOut) AS sellCount,
     coalesce(avg(tOut.feeNumeric), 0.0) AS avgSellFee
SET c.buyCount      = toFloat(buyCount),
    c.sellCount     = toFloat(sellCount),
    c.totalActivity = toFloat(buyCount + sellCount),
    c.avgBuyFee     = avgBuyFee,
    c.avgSellFee    = avgSellFee;

MATCH (buyer:Club)<-[:TO_CLUB]-(t:Transfer)-[:FROM_CLUB]->(seller:Club)
OPTIONAL MATCH (buyer)-[:PART_OF]->(buyerCountry:Country)
OPTIONAL MATCH (seller)-[:PART_OF]->(sellerCountry:Country)
WITH buyer,
     count(t) AS totalBuys,
     sum(CASE WHEN buyerCountry.name IS NOT NULL
                AND sellerCountry.name IS NOT NULL
                AND buyerCountry.name <> sellerCountry.name
              THEN 1 ELSE 0 END) AS foreignBuys
SET buyer.crossBorderBuyRatio =
    CASE WHEN totalBuys = 0 THEN 0.0
         ELSE toFloat(foreignBuys) / toFloat(totalBuys) END;


// ============================================================
// SECTION 3: SUPERVISED LABEL (buyerClass)
// ============================================================
// HighBuyer (1) if buyCount >= 75th percentile, else LowBuyer (0)

MATCH (c:Club)
WITH percentileCont(c.buyCount, 0.75) AS p75
MATCH (c:Club)
SET c.buyerClass = CASE WHEN c.buyCount >= p75 THEN 1 ELSE 0 END;

MATCH (c:Club)
RETURN c.buyerClass AS Class, count(*) AS Clubs
ORDER BY Class DESC;


// ============================================================
// SECTION 4: GRAPH PROJECTION FOR GDS ALGORITHMS
// ============================================================
// Undirected projection — needed for Louvain community detection.

CALL gds.graph.project(
  'club-ml-graph',
  'Club',
  {
    SOLD_TO: {
      orientation: 'UNDIRECTED',
      properties: ['deals']
    }
  }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;


// ============================================================
// SECTION 5: LOUVAIN COMMUNITY DETECTION
// ============================================================
// Writes `community` property on each Club node.

CALL gds.louvain.write('club-ml-graph', {
  writeProperty: 'community'
})
YIELD communityCount, modularity, modularities
RETURN communityCount, modularity;


// ============================================================
// SECTION 6: PAGERANK
// ============================================================
// Writes `pagerank` property on each Club node.

CALL gds.pageRank.write('club-ml-graph', {
  writeProperty: 'pagerank'
})
YIELD nodePropertiesWritten, ranIterations
RETURN nodePropertiesWritten, ranIterations;


// ============================================================
// SECTION 7: FASTRP NODE EMBEDDINGS
// ============================================================
// Writes `embedding` (vector of length 64) per Club node.
// Used as ML feature input in Python notebooks.

CALL gds.fastRP.write('club-ml-graph', {
  writeProperty: 'embedding',
  embeddingDimension: 64,
  randomSeed: 42
})
YIELD nodePropertiesWritten
RETURN nodePropertiesWritten;


// ============================================================
// SECTION 8: VERIFICATION
// ============================================================

MATCH (c:Club)
RETURN c.name              AS Club,
       c.buyCount           AS BuyCount,
       c.sellCount          AS SellCount,
       c.community          AS Community,
       round(c.pagerank, 4) AS PageRank,
       size(c.embedding)    AS EmbeddingDim,
       c.buyerClass         AS BuyerClass
ORDER BY c.buyCount DESC
LIMIT 10;


// ============================================================
// SECTION 9: DROP THE PROJECTION (cleanup)
// ============================================================
//
// We can drop the in-memory projection now because the values
// were written back to the database as node properties.
// ============================================================

CALL gds.graph.drop('club-ml-graph');


// ============================================================
// END OF PHASE 1 — Now run Phase 2 and Phase 3 notebooks.
// ============================================================
