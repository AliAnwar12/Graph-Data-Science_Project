// ============================================================
// CS343 Graph Data Science - Spring 2026
// Milestone 3: Node Classification Pipeline (Version-Robust)
// Dataset: Football Transfers (2017/2018)
// Team: Muhammad Ammar Maqdoom, Ali Anwar
// ============================================================
//
// WHY THIS VERSION?
// This script avoids fragile version-specific GDS pipeline procedures.
// It implements a complete ML workflow directly in Cypher:
// 1) Define labels (supervised target)
// 2) Engineer graph features
// 3) Train/test split
// 4) Train a centroid-based classifier
// 5) Evaluate (confusion matrix, accuracy, precision, recall, F1)
//
// ML PROBLEM:
// Node Classification on :Club nodes
// Target label: buyerClass (1 = HighBuyer, 0 = LowBuyer)
//
// ============================================================
// SECTION 1: SANITY CHECK
// ============================================================

MATCH (c:Club) RETURN count(c) AS ClubCount;
MATCH (t:Transfer) RETURN count(t) AS TransferCount;


// ============================================================
// SECTION 2: FEATURE ENGINEERING ON CLUB NODES
// ============================================================
//
// Features:
// - buyCount: number of incoming transfers
// - sellCount: number of outgoing transfers
// - totalActivity: buyCount + sellCount
// - avgBuyFee: average feeNumeric of bought players
// - avgSellFee: average feeNumeric of sold players
// - crossBorderBuyRatio: fraction of buys from foreign countries
// ============================================================

MATCH (c:Club)
OPTIONAL MATCH (tIn:Transfer)-[:TO_CLUB]->(c)
WITH c, count(tIn) AS buyCount, coalesce(avg(tIn.feeNumeric), 0.0) AS avgBuyFee
OPTIONAL MATCH (tOut:Transfer)-[:FROM_CLUB]->(c)
WITH c, buyCount, avgBuyFee,
     count(tOut) AS sellCount,
     coalesce(avg(tOut.feeNumeric), 0.0) AS avgSellFee
SET c.buyCount = toFloat(buyCount),
    c.sellCount = toFloat(sellCount),
    c.totalActivity = toFloat(buyCount + sellCount),
    c.avgBuyFee = avgBuyFee,
    c.avgSellFee = avgSellFee;

MATCH (c:Club)
SET c.crossBorderBuyRatio = 0.0;

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
    CASE WHEN totalBuys = 0 THEN 0.0 ELSE toFloat(foreignBuys) / toFloat(totalBuys) END;

// Verify engineered features
MATCH (c:Club)
RETURN c.name AS Club, c.buyCount AS buyCount, c.sellCount AS sellCount,
       c.avgBuyFee AS avgBuyFee, c.crossBorderBuyRatio AS crossBorderBuyRatio
ORDER BY buyCount DESC
LIMIT 10;


// ============================================================
// SECTION 3: CREATE SUPERVISED LABEL (buyerClass)
// ============================================================
//
// Label definition:
// buyerClass = 1 (HighBuyer) if buyCount >= 75th percentile
// buyerClass = 0 (LowBuyer) otherwise
//
// This creates a realistic supervised classification target.
// ============================================================

MATCH (c:Club)
WITH percentileCont(c.buyCount, 0.75) AS p75
MATCH (c:Club)
SET c.buyerClass = CASE WHEN c.buyCount >= p75 THEN 1 ELSE 0 END;

MATCH (c:Club)
RETURN c.buyerClass AS ClassLabel, count(*) AS Clubs
ORDER BY ClassLabel DESC;


// ============================================================
// SECTION 4: TRAIN/TEST SPLIT (DETERMINISTIC)
// ============================================================
//
// Deterministic split avoids random differences between runs:
// - TRAIN: 80%
// - TEST : 20%
// ============================================================

MATCH (c:Club)
SET c.mlSplit = CASE WHEN abs(id(c)) % 10 < 8 THEN 'TRAIN' ELSE 'TEST' END;

MATCH (c:Club)
RETURN c.mlSplit AS Split, count(*) AS Clubs
ORDER BY Split;


// ============================================================
// SECTION 5: TRAIN CENTROID CLASSIFIER (USING TRAIN SET)
// ============================================================
//
// Model: nearest-centroid classifier
// Feature vector per club:
// [buyCount, sellCount, avgBuyFee, avgSellFee, crossBorderBuyRatio]
//
// We compute one centroid for class 0 and one for class 1 from TRAIN nodes.
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TRAIN'
WITH
  avg(CASE WHEN c.buyerClass = 1 THEN c.buyCount END)            AS c1_buyCount,
  avg(CASE WHEN c.buyerClass = 1 THEN c.sellCount END)           AS c1_sellCount,
  avg(CASE WHEN c.buyerClass = 1 THEN c.avgBuyFee END)           AS c1_avgBuyFee,
  avg(CASE WHEN c.buyerClass = 1 THEN c.avgSellFee END)          AS c1_avgSellFee,
  avg(CASE WHEN c.buyerClass = 1 THEN c.crossBorderBuyRatio END) AS c1_crossBorder,
  avg(CASE WHEN c.buyerClass = 0 THEN c.buyCount END)            AS c0_buyCount,
  avg(CASE WHEN c.buyerClass = 0 THEN c.sellCount END)           AS c0_sellCount,
  avg(CASE WHEN c.buyerClass = 0 THEN c.avgBuyFee END)           AS c0_avgBuyFee,
  avg(CASE WHEN c.buyerClass = 0 THEN c.avgSellFee END)          AS c0_avgSellFee,
  avg(CASE WHEN c.buyerClass = 0 THEN c.crossBorderBuyRatio END) AS c0_crossBorder
MATCH (x:Club)
WHERE x.mlSplit = 'TEST'
WITH x,
     c1_buyCount, c1_sellCount, c1_avgBuyFee, c1_avgSellFee, c1_crossBorder,
     c0_buyCount, c0_sellCount, c0_avgBuyFee, c0_avgSellFee, c0_crossBorder,
     (
       (x.buyCount            - c1_buyCount)^2 +
       (x.sellCount           - c1_sellCount)^2 +
       (x.avgBuyFee           - c1_avgBuyFee)^2 +
       (x.avgSellFee          - c1_avgSellFee)^2 +
       (x.crossBorderBuyRatio - c1_crossBorder)^2
     ) AS d1,
     (
       (x.buyCount            - c0_buyCount)^2 +
       (x.sellCount           - c0_sellCount)^2 +
       (x.avgBuyFee           - c0_avgBuyFee)^2 +
       (x.avgSellFee          - c0_avgSellFee)^2 +
       (x.crossBorderBuyRatio - c0_crossBorder)^2
     ) AS d0
SET x.predBuyerClass = CASE WHEN d1 < d0 THEN 1 ELSE 0 END,
    x.distToClass1 = d1,
    x.distToClass0 = d0;

// Preview predictions
MATCH (c:Club)
WHERE c.mlSplit = 'TEST'
RETURN c.name AS Club,
       c.buyerClass AS Actual,
       c.predBuyerClass AS Predicted,
       round(c.distToClass1, 2) AS DistToClass1,
       round(c.distToClass0, 2) AS DistToClass0
ORDER BY Club
LIMIT 20;


// ============================================================
// SECTION 6: EVALUATION METRICS ON TEST SET
// ============================================================
//
// Metrics:
// - Confusion matrix: TP, TN, FP, FN
// - Accuracy
// - Precision
// - Recall
// - F1
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TEST'
WITH
  sum(CASE WHEN c.buyerClass = 1 AND c.predBuyerClass = 1 THEN 1 ELSE 0 END) AS TP,
  sum(CASE WHEN c.buyerClass = 0 AND c.predBuyerClass = 0 THEN 1 ELSE 0 END) AS TN,
  sum(CASE WHEN c.buyerClass = 0 AND c.predBuyerClass = 1 THEN 1 ELSE 0 END) AS FP,
  sum(CASE WHEN c.buyerClass = 1 AND c.predBuyerClass = 0 THEN 1 ELSE 0 END) AS FN
RETURN
  TP, TN, FP, FN,
  round(toFloat(TP + TN) / toFloat(TP + TN + FP + FN), 4) AS Accuracy,
  round(CASE WHEN TP + FP = 0 THEN 0.0 ELSE toFloat(TP) / toFloat(TP + FP) END, 4) AS Precision,
  round(CASE WHEN TP + FN = 0 THEN 0.0 ELSE toFloat(TP) / toFloat(TP + FN) END, 4) AS Recall,
  round(
    CASE
      WHEN (2 * TP + FP + FN) = 0 THEN 0.0
      ELSE (2.0 * TP) / toFloat(2 * TP + FP + FN)
    END, 4
  ) AS F1;


// ============================================================
// SECTION 7: INTERPRETABLE RESULT TABLE FOR REPORT
// ============================================================
//
// Shows test clubs where model predicts HighBuyer.
// Useful as "recommendation-like" output for analyst focus.
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TEST' AND c.predBuyerClass = 1
RETURN
  c.name AS Club,
  c.buyCount AS BuyCount,
  c.sellCount AS SellCount,
  round(c.avgBuyFee, 2) AS AvgBuyFeeMillion,
  round(c.crossBorderBuyRatio, 3) AS CrossBorderBuyRatio,
  c.buyerClass AS ActualLabel,
  c.predBuyerClass AS PredictedLabel
ORDER BY BuyCount DESC, AvgBuyFeeMillion DESC
LIMIT 20;


// ============================================================
// SECTION 8: PER-CLASS ACCURACY BREAKDOWN (TEST SET)
// ============================================================
//
// Shows accuracy of each class separately.
// Useful to understand if the model is biased toward the
// majority class (LowBuyer) or balanced across both classes.
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TEST'
RETURN
  c.buyerClass AS ActualClass,
  count(*)     AS Total,
  sum(CASE WHEN c.predBuyerClass = c.buyerClass THEN 1 ELSE 0 END) AS Correct,
  round(
    100.0 * sum(CASE WHEN c.predBuyerClass = c.buyerClass THEN 1 ELSE 0 END)
          / count(*),
    2
  ) AS AccuracyPct
ORDER BY ActualClass DESC;


// ============================================================
// SECTION 9: PER-CLASS FEATURE PROFILE (TRAIN SET)
// ============================================================
//
// Shows average feature values per class from the TRAIN split.
// Helps explain WHY the classifier works:
// HighBuyer clubs should have significantly higher buyCount,
// fees, and cross-border ratio than LowBuyers.
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TRAIN'
WITH c.buyerClass AS cls,
     avg(c.buyCount)            AS avgBuyCount,
     avg(c.sellCount)           AS avgSellCount,
     avg(c.avgBuyFee)           AS avgBuyFee,
     avg(c.avgSellFee)          AS avgSellFee,
     avg(c.crossBorderBuyRatio) AS avgCrossBorder
RETURN
  cls                        AS Class,
  round(avgBuyCount, 2)      AS AvgBuyCount,
  round(avgSellCount, 2)     AS AvgSellCount,
  round(avgBuyFee, 2)        AS AvgBuyFee,
  round(avgSellFee, 2)       AS AvgSellFee,
  round(avgCrossBorder, 3)   AS AvgCrossBorder
ORDER BY Class DESC;


// ============================================================
// SECTION 10: TOP MISCLASSIFICATIONS (TEST SET)
// ============================================================
//
// Lists test clubs where the model was wrong, sorted by the
// smallest margin between class distances (most borderline cases
// first). Good material for discussing model limitations.
// ============================================================

MATCH (c:Club)
WHERE c.mlSplit = 'TEST' AND c.predBuyerClass <> c.buyerClass
RETURN
  c.name              AS Club,
  c.buyerClass        AS Actual,
  c.predBuyerClass    AS Predicted,
  round(c.distToClass1, 2) AS DistToClass1,
  round(c.distToClass0, 2) AS DistToClass0,
  round(abs(c.distToClass1 - c.distToClass0), 2) AS DistanceMargin
ORDER BY DistanceMargin ASC
LIMIT 20;


// ============================================================
// END OF MILESTONE 3 SCRIPT
// ============================================================
