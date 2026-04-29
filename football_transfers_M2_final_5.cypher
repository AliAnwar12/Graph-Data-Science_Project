// ============================================================
// CS343 Graph Data Science - Spring 2026
// Milestone 2: Data Loading + Graph Statistics & Analytics
// Dataset: Football (Soccer) Transfers - Season 2017/2018
// Team: Muhammad Ammar Maqdoom, Ali Anwar
// ============================================================


// ============================================================
// SECTION 1: GRAPH MODEL DESIGN RATIONALE
// ============================================================
//
// The Football Transfers dataset is naturally modeled as a graph because
// transfers inherently describe *relationships* between entities.
//
//   NODE TYPES:
//   - Player   : A football player (identified by playerUri)
//   - Club     : A football club (buyer or seller)
//   - Country  : A nation (associated with players and clubs)
//   - Transfer : Reified as a node to store fee, season, loan status, timestamp
//                (Transfer is a node rather than a direct edge because it has
//                 its own properties, and a player can move between the same
//                 two clubs multiple times)
//
//   RELATIONSHIP TYPES:
//   (:Player)-[:MADE_TRANSFER]->(:Transfer)
//       A player is the subject of a transfer event
//   (:Transfer)-[:FROM_CLUB]->(:Club)
//       The club selling/releasing the player
//   (:Transfer)-[:TO_CLUB]->(:Club)
//       The club buying/receiving the player
//   (:Club)-[:PART_OF]->(:Country)
//       Each club belongs to a country/league
//   (:Player)-[:NATIONALITY]->(:Country)
//       Each player has a national identity
//
//   WHY THIS MODEL?
//   - Transfer fees and loan flags are first-class properties on Transfer nodes
//   - Querying paths between clubs via shared player movements is natural
//   - Country nodes enable league-level aggregation queries
//   - MERGE ensures no duplicate nodes even with repeated CSV entries
//   - Season filter (2017/2018) scopes analysis to a single transfer window
//   - Timestamp enables temporal ordering for intermediary chain detection
//
//   CSV COLUMNS:
//   season, playerUri, playerName, playerPosition, playerAge,
//   sellerClubUri, sellerClubName, sellerClubCountry,
//   buyerClubUri, buyerClubName, buyerClubCountry,
//   transferUri, transferFee, playerImage, playerNationality, timestamp
//
//   2017/2018 season: 25,505 rows
// ============================================================


// ============================================================
// SECTION 2: CONSTRAINTS & INDEXES
// Run these FIRST before importing any data.
// Constraints prevent duplicate nodes and speed up MERGE operations.
// ============================================================

CREATE CONSTRAINT player_id_unique IF NOT EXISTS
FOR (p:Player) REQUIRE p.id IS UNIQUE;

CREATE CONSTRAINT club_id_unique IF NOT EXISTS
FOR (c:Club) REQUIRE c.id IS UNIQUE;

CREATE CONSTRAINT transfer_id_unique IF NOT EXISTS
FOR (t:Transfer) REQUIRE t.id IS UNIQUE;

CREATE CONSTRAINT country_name_unique IF NOT EXISTS
FOR (c:Country) REQUIRE c.name IS UNIQUE;


// ============================================================
// SECTION 3: DATA LOADING
// Source: Official Neo4j football transfers CSV.
// Season filter: 2017/2018 only.
// Run each query one at a time in order (3a through 3i)
// ============================================================

// --- 3a: Load Player Nodes ---
// MERGE on playerUri (unique identifier) to avoid duplicates.
// playerImage column exists in CSV but excluded (no analytical value).
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018'
MERGE (player:Player {id: row.playerUri})
  ON CREATE SET
    player.name     = row.playerName,
    player.position = row.playerPosition,
    player.age      = row.playerAge;

// --- 3b: Load Country Nodes (from Player Nationality) ---
// DISTINCT prevents redundant MERGE calls for the same country.
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018' AND row.playerNationality <> ''
WITH DISTINCT row.playerNationality AS nationality
MERGE (:Country {name: nationality});

// --- 3c: Load Club Nodes (Seller and Buyer) ---
// NULL/empty URI check prevents merge errors on incomplete rows.
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018'
AND row.sellerClubUri IS NOT NULL AND row.sellerClubUri <> ''
AND row.buyerClubUri  IS NOT NULL AND row.buyerClubUri  <> ''
MERGE (seller:Club {id: row.sellerClubUri})
  ON CREATE SET seller.name = row.sellerClubName
MERGE (buyer:Club {id: row.buyerClubUri})
  ON CREATE SET buyer.name = row.buyerClubName;

// --- 3d: Link Clubs to Countries ---
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018'
AND row.sellerClubUri IS NOT NULL AND row.sellerClubUri <> ''
AND row.buyerClubUri  IS NOT NULL AND row.buyerClubUri  <> ''
MATCH (seller:Club {id: row.sellerClubUri})
MATCH (buyer:Club  {id: row.buyerClubUri})
MERGE (sellerCountry:Country {name: row.sellerClubCountry})
MERGE (buyerCountry:Country  {name: row.buyerClubCountry})
MERGE (seller)-[:PART_OF]->(sellerCountry)
MERGE (buyer)-[:PART_OF]->(buyerCountry);

// --- 3e: Load Transfer Nodes + Wire All Relationships ---
// transferUri is the unique ID for each transfer event.
// Connects: Player --MADE_TRANSFER--> Transfer
//                                     Transfer --FROM_CLUB--> Seller
//                                     Transfer --TO_CLUB-->   Buyer
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018' AND row.transferUri IS NOT NULL
AND row.sellerClubUri IS NOT NULL AND row.sellerClubUri <> ''
AND row.buyerClubUri  IS NOT NULL AND row.buyerClubUri  <> ''
MERGE (transfer:Transfer {id: row.transferUri})
  ON CREATE SET
    transfer.fee    = row.transferFee,
    transfer.season = row.season
WITH row, transfer
MATCH (player:Player {id: row.playerUri})
MATCH (seller:Club   {id: row.sellerClubUri})
MATCH (buyer:Club    {id: row.buyerClubUri})
MERGE (player)-[:MADE_TRANSFER]->(transfer)
MERGE (transfer)-[:FROM_CLUB]->(seller)
MERGE (transfer)-[:TO_CLUB]->(buyer);

// --- 3f: Link Players to Nationality ---
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018' AND row.playerNationality <> ''
MATCH (player:Player {id: row.playerUri})
MATCH (country:Country {name: row.playerNationality})
MERGE (player)-[:NATIONALITY]->(country);

// --- 3g: Tag Loan Transfers with a Second Label ---
// Uses toLower() + CONTAINS for multilingual detection.
MATCH (t:Transfer)
WHERE toLower(t.fee) CONTAINS 'loan'
SET t:Loan;

// --- 3h: Add Numeric Fee Property ---
// Handles multiple fee formats in the dataset:
//   £7.20m        -> strip £ and m, parse directly as millions
//   £900k         -> strip £ and k, divide by 1000 to get millions
//   €56           -> strip €, divide by 1,000,000
//   Free transfer -> 0.0 (also: gratuito=Portuguese, ablösefrei=German)
//   - / ? / Loan  -> 0.0
MATCH (t:Transfer)
WITH t,
     CASE
       WHEN t.fee =~ '.*[0-9].*m'
         THEN toFloat(replace(replace(replace(replace(t.fee, '£',''), '€',''), 'm',''), ',','.'))
       WHEN t.fee =~ '[£€][0-9]+[k]'
         THEN toFloat(replace(replace(replace(t.fee, '£',''), '€',''), 'k','')) / 1000.0
       WHEN t.fee =~ '[£€][0-9]+'
         THEN toFloat(replace(replace(t.fee, '£',''), '€','')) / 1000000.0
       ELSE 0.0
     END AS numericFee
SET t.feeNumeric = numericFee;

// --- 3i: Add Timestamp Property to Transfer Nodes ---
// Unix timestamp from CSV enables time-based ordering of transfers.
// Essential for GA-13 intermediary chain detection (same transfer window).
LOAD CSV WITH HEADERS FROM
  'https://s3-eu-west-1.amazonaws.com/football-transfers.neo4j.com/transfers-all.csv'
AS row
WITH row WHERE row.season = '2017/2018' AND row.transferUri IS NOT NULL
MATCH (t:Transfer {id: row.transferUri})
SET t.timestamp = toInteger(row.timestamp);

// --- Verify Loading ---
// Returns counts by node label to validate import completeness.
MATCH (n)
RETURN labels(n)[0] AS NodeType, count(n) AS Total
ORDER BY Total DESC;


// ============================================================
// SECTION 4: GRAPH STATISTICS (GS)
// Graph statistics queries for structure and connectivity.
// Covers: node/edge counts, degree, in/out-degree, density,
//         clustering coefficient, average path length, diameter
// ============================================================

// --- GS-1: Total Node Count by Type ---
MATCH (n)
RETURN labels(n)[0] AS NodeType, count(n) AS Total
ORDER BY Total DESC;

// --- GS-2: Total Relationship Count by Type ---
// Each Transfer should have exactly one FROM_CLUB, one TO_CLUB, one MADE_TRANSFER.
MATCH ()-[r]->()
RETURN type(r) AS RelationshipType, count(r) AS Total
ORDER BY Total DESC;

// --- GS-3: Degree of Each Club Node ---
// Degree = total number of relationships connected to each club.
MATCH (c:Club)
OPTIONAL MATCH (c)-[r]-()
RETURN c.name AS Club, COUNT(r) AS Degree
ORDER BY Degree DESC
LIMIT 20;

// --- GS-4: In-Degree of Clubs (Transfers Received) ---
// In-degree counts incoming relationships.
// Clubs with high in-degree are the biggest buyers in the market.
MATCH (c:Club)
OPTIONAL MATCH (c)<-[r]-()
RETURN c.name AS Club, COUNT(r) AS InDegree
ORDER BY InDegree DESC
LIMIT 10;

// --- GS-5: Out-Degree of Clubs (Transfers Sent) ---
// Out-degree counts outgoing relationships.
// Clubs with high out-degree are the biggest sellers.
MATCH (c:Club)
OPTIONAL MATCH (c)-[r]->()
RETURN c.name AS Club, COUNT(r) AS OutDegree
ORDER BY OutDegree DESC
LIMIT 10;

// --- GS-6: Degree Distribution of the Graph ---
// Degree distribution = frequency of nodes with different degrees.
// Returns the number of nodes for each degree value.
MATCH (m)
OPTIONAL MATCH (m)-[r]-()
WITH m, count(r) AS degree
RETURN degree, count(degree) AS NumberOfNodes
ORDER BY degree ASC;

// --- GS-6b: Degree Summary per Node Type ---
// Computes min, max, average, and median degree by node type.
MATCH (n)
OPTIONAL MATCH (n)-[r]-()
WITH labels(n)[0] AS NodeType, n, count(r) AS degree
RETURN NodeType,
       min(degree)                 AS MinDegree,
       max(degree)                 AS MaxDegree,
       round(avg(degree), 2)       AS AvgDegree,
       percentileCont(degree, 0.5) AS MedianDegree
ORDER BY MaxDegree DESC;

// --- GS-7: Isolated Clubs (degree = 0) ---
// Counts clubs with no inbound or outbound transfer relationships.
MATCH (c:Club)
WHERE NOT (c)<-[:FROM_CLUB]-() AND NOT (c)<-[:TO_CLUB]-()
RETURN count(c) AS IsolatedClubs;

// --- GS-8: Players with Only One Transfer ---
// Analogous to "movies with only one actor" from the project guide.
MATCH (p:Player)-[:MADE_TRANSFER]->(t:Transfer)
WITH p, count(t) AS numTransfers
WHERE numTransfers = 1
RETURN count(p) AS PlayersWithSingleTransfer;

// --- GS-9: Graph Density ---
// Density = ratio of actual edges to the maximum possible edges.
// Formula: E / (V*(V-1)/2)
MATCH (m)
OPTIONAL MATCH (m)-[r]-()
WITH count(DISTINCT m) AS V, count(DISTINCT r) AS E
RETURN V, E, toFloat(E) / ((V*(V-1))/2) AS Density;

// --- GS-10: Transfer Fee Type Breakdown ---
// Classifies transfer fees into free, undisclosed, loan, draft, paid, and other.
MATCH (t:Transfer)
RETURN
  CASE
    WHEN toLower(t.fee) CONTAINS 'free'
      OR toLower(t.fee) CONTAINS 'gratuito'
      OR toLower(t.fee) CONTAINS 'ablösefrei'
      OR t.fee = '0'                          THEN 'Free'
    WHEN t.fee = '-' OR t.fee = '?'           THEN 'Undisclosed'
    WHEN toLower(t.fee) CONTAINS 'loan'       THEN 'Loan'
    WHEN toLower(t.fee) CONTAINS 'draft'      THEN 'Draft'
    WHEN t.feeNumeric > 0                     THEN 'Paid'
    ELSE 'Other'
  END AS TransferType,
  count(t) AS Count
ORDER BY Count DESC;

// --- GS-11: Clustering Coefficient per Club (GDS) ---
// Local clustering coefficient formula: C_i = 2*L / (k*(k-1)).
// localClusteringCoefficient requires UNDIRECTED relationships in the projected graph.
// Since transfer data is modeled as Transfer -> Club edges, we first materialize a direct
// Club-to-Club relation (:TRANSFER_WITH), then project it as UNDIRECTED for GDS.
//
// Step 0: Drop old in-memory graph (safe on reruns)
CALL gds.graph.drop('club-cc-graph', false);

// Step 1: Build direct Club-to-Club relationships from transfer events
MATCH (seller:Club)<-[:FROM_CLUB]-(:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
MERGE (seller)-[:TRANSFER_WITH]->(buyer);

// Step 2: Project UNDIRECTED Club graph for clustering coefficient
CALL gds.graph.project(
  'club-cc-graph',
  'Club',
  { TRANSFER_WITH: { orientation: 'UNDIRECTED' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Step 3: Run Local Clustering Coefficient
CALL gds.localClusteringCoefficient.stream('club-cc-graph')
YIELD nodeId, localClusteringCoefficient
WITH gds.util.asNode(nodeId) AS c, localClusteringCoefficient
MATCH (c)-[:TRANSFER_WITH]-(:Club)
WITH c, localClusteringCoefficient, count(*) AS degree
WHERE degree >= 5
RETURN c.name AS Club,
       degree AS k,
       round(localClusteringCoefficient, 4) AS ClusteringCoefficient
ORDER BY ClusteringCoefficient DESC, k DESC
LIMIT 15;

// Step 4: Drop projection
CALL gds.graph.drop('club-cc-graph');


// ============================================================
// SECTION 5: GRAPH ANALYTICS (GA)
// Graph analytics queries for paths, connectivity, and centrality.
// Covers: Path Analytics, Connectivity, Centrality,
//         Community Detection, Pattern Detection
// ============================================================

// --- GA-1: Most Active Clubs (Buyer + Seller Combined) ---
// Ranks clubs by combined sold and bought transfer activity.
MATCH (c:Club)
OPTIONAL MATCH (c)<-[:FROM_CLUB]-(sold:Transfer)
OPTIONAL MATCH (c)<-[:TO_CLUB]-(bought:Transfer)
RETURN
  c.name AS Club,
  count(DISTINCT sold)                          AS Sold,
  count(DISTINCT bought)                        AS Bought,
  count(DISTINCT sold) + count(DISTINCT bought) AS TotalActivity
ORDER BY TotalActivity DESC
LIMIT 10;

// --- GA-2: Pattern Detection — Who Bought Most FROM a Specific Club? ---
// Finds clubs that most frequently buy players from a selected seller club.
MATCH (seller:Club {name: 'Juventus'})
MATCH (t:Transfer)-[:FROM_CLUB]->(seller)
MATCH (t)-[:TO_CLUB]->(buyer:Club)
RETURN buyer.name AS BoughtFromJuventus, count(t) AS Transfers
ORDER BY Transfers DESC
LIMIT 10;

// --- GA-3: Path Analytics — Find Exact Club Names First ---
// Run this before the shortestPath query to get exact stored names.
MATCH (c:Club)
WHERE toLower(c.name) CONTAINS 'barcelona'
   OR toLower(c.name) CONTAINS 'juventus'
RETURN c.name AS ClubName
ORDER BY c.name;

// Then run shortest path with exact names:
MATCH
  (a:Club {name: 'FC Barcelona'}),
  (b:Club {name: 'Juventus'}),
  path = shortestPath((a)<-[:FROM_CLUB|TO_CLUB*..10]-(b))
RETURN path, length(path) AS PathLength;

// --- GA-4: Connectivity — Top Selling Countries (Feeder Leagues) ---
// High out-flow = feeder network for richer leagues.
MATCH (seller:Club)-[:PART_OF]->(country:Country)
MATCH (t:Transfer)-[:FROM_CLUB]->(seller)
RETURN country.name AS SellerCountry, count(t) AS TransfersOut
ORDER BY TransfersOut DESC
LIMIT 10;

// --- GA-5: Connectivity — Top Buying Countries ---
MATCH (buyer:Club)-[:PART_OF]->(country:Country)
MATCH (t:Transfer)-[:TO_CLUB]->(buyer)
RETURN country.name AS BuyerCountry, count(t) AS TransfersIn
ORDER BY TransfersIn DESC
LIMIT 10;

// --- GA-6: Most Expensive Transfers (2017/2018) ---
// Lists the highest-fee transfers by player, source club, and destination club.
MATCH (p:Player)-[:MADE_TRANSFER]->(t:Transfer)
MATCH (t)-[:FROM_CLUB]->(seller:Club)
MATCH (t)-[:TO_CLUB]->(buyer:Club)
WHERE t.feeNumeric > 0
RETURN
  p.name       AS Player,
  seller.name  AS From,
  buyer.name   AS To,
  t.feeNumeric AS FeeMillion,
  t.season     AS Season
ORDER BY FeeMillion DESC
LIMIT 10;

// --- GA-7: Clubs That Repeatedly Trade Together ---
// High deal count between same two clubs = strong bilateral partnership.
MATCH (seller:Club)<-[:FROM_CLUB]-(t:Transfer)-[:TO_CLUB]->(buyer:Club)
WITH seller, buyer, count(t) AS deals
WHERE deals > 1
RETURN seller.name AS From, buyer.name AS To, deals AS NumberOfDeals
ORDER BY deals DESC
LIMIT 15;

// --- GA-8: Centrality — Most Traveled Players ---
// Finds players with the highest transfer counts.
MATCH (p:Player)-[:MADE_TRANSFER]->(t:Transfer)
WITH p, count(t) AS numTransfers
ORDER BY numTransfers DESC
LIMIT 10
RETURN p.name AS Player, numTransfers AS Transfers;

// --- GA-9: Centrality — Countries as Bridge Nodes ---
// Measures country-level bridge connectivity via cross-country transfers.
MATCH (buyerClub:Club)-[:PART_OF]->(buyerCountry:Country)
MATCH (sellerClub:Club)-[:PART_OF]->(sellerCountry:Country)
MATCH (t:Transfer)-[:FROM_CLUB]->(sellerClub)
MATCH (t)-[:TO_CLUB]->(buyerClub)
WHERE buyerCountry <> sellerCountry
WITH buyerCountry.name AS Country,
     count(DISTINCT sellerCountry) AS ForeignCountriesConnectedTo
ORDER BY ForeignCountriesConnectedTo DESC
LIMIT 10
RETURN Country, ForeignCountriesConnectedTo;

// --- GA-10: Nationality Diversity per Club ---
MATCH (t:Transfer)-[:TO_CLUB]->(club:Club)
MATCH (p:Player)-[:MADE_TRANSFER]->(t)
MATCH (p)-[:NATIONALITY]->(country:Country)
WITH club.name AS Club, count(DISTINCT country.name) AS NationalitiesSignedFrom
ORDER BY NationalitiesSignedFrom DESC
LIMIT 10
RETURN Club, NationalitiesSignedFrom;

// --- GA-11: Average Path Length (sampled) ---
// Estimates average shortest-path length between club pairs using sampling.
// Path length is bounded for performance.
MATCH (start:Club)
WITH start LIMIT 50
MATCH (end:Club)
WHERE start <> end
WITH start, end LIMIT 500
MATCH path = shortestPath((start)-[*..15]-(end))
RETURN avg(length(path)) AS AveragePathLength;

// --- GA-12: Diameter of Transfer Network (sampled) ---
// Estimates network diameter as the maximum sampled shortest-path length.
MATCH (start:Club)
WITH start LIMIT 50
MATCH (end:Club)
WHERE start <> end
WITH start, end LIMIT 500
MATCH path = shortestPath((start)-[*..15]-(end))
RETURN max(length(path)) AS Diameter;

// --- GA-13: True Player Intermediary Chains ---
// Detects player movements that pass through an intermediary club in sequence.
// Applies filters for same player, temporal order, transfer-window proximity,
// team-name cleanup (B/youth/reserve), and valid inbound/outbound transfer types.
MATCH (source:Club)<-[:FROM_CLUB]-(t2:Transfer)-[:TO_CLUB]->(mid:Club)
MATCH (mid)<-[:FROM_CLUB]-(t1:Transfer)-[:TO_CLUB]->(dest:Club)
MATCH (p:Player)-[:MADE_TRANSFER]->(t2)
MATCH (p)-[:MADE_TRANSFER]->(t1)
WHERE source <> dest AND source <> mid AND dest <> mid
AND NOT toLower(source.name) CONTAINS ' b'
AND NOT toLower(source.name) CONTAINS 'u19'
AND NOT toLower(source.name) CONTAINS 'u21'
AND NOT toLower(source.name) CONTAINS 'u23'
AND NOT toLower(source.name) CONTAINS 'ii'
AND NOT toLower(source.name) CONTAINS 'reserve'
AND NOT toLower(mid.name) CONTAINS ' b'
AND NOT toLower(mid.name) CONTAINS 'u19'
AND NOT toLower(mid.name) CONTAINS 'u21'
AND NOT toLower(mid.name) CONTAINS 'u23'
AND NOT toLower(mid.name) CONTAINS 'ii'
AND NOT toLower(mid.name) CONTAINS 'reserve'
AND NOT toLower(dest.name) CONTAINS ' b'
AND NOT toLower(dest.name) CONTAINS 'ii'
AND t1.timestamp >= t2.timestamp
AND (t1.timestamp - t2.timestamp) <= 15552000
AND (t2.feeNumeric > 0 OR toLower(t2.fee) CONTAINS 'loan')
AND (toLower(t1.fee) CONTAINS 'loan' OR t1.feeNumeric > 0)
RETURN
  p.name      AS Player,
  source.name AS OriginalClub,
  mid.name    AS Intermediary,
  dest.name   AS Destination,
  t2.fee      AS FeeIn,
  t1.fee      AS FeeOut,
  t1.timestamp - t2.timestamp AS SecondsBetween
ORDER BY SecondsBetween ASC
LIMIT 15;


// ============================================================
// SECTION 6: GDS ALGORITHMS
// Requires Neo4j Desktop with the GDS plugin installed.
// Workflow per algorithm: Project -> Run Algorithm -> Drop Projection
// Uses native GDS projection (gds.graph.project).
// Transfer nodes collapsed into direct Club-to-Club edges via orientation config.
// ============================================================

// Verify GDS is available:
RETURN gds.version();

// ============================================================
// GDS-1: PageRank Centrality
// PageRank identifies the most influential clubs in the transfer
// network by propagating importance through incoming transfer edges.
// Higher score = more important clubs transfer TO this club.
// ============================================================

// Step 0: Drop old in-memory graph (safe on reruns)
CALL gds.graph.drop('club-pagerank-graph', false);

// Step 1: Materialize directed Club->Club edges (seller -> buyer)
MATCH (seller:Club)<-[:FROM_CLUB]-(:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
MERGE (seller)-[:SOLD_TO]->(buyer);

// Step 2: Native projection — directed Club-to-Club graph
CALL gds.graph.project(
  'club-pagerank-graph',
  'Club',
  { SOLD_TO: { orientation: 'NATURAL' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Step 3: Run PageRank in stream mode
CALL gds.pageRank.stream('club-pagerank-graph')
YIELD nodeId, score
RETURN gds.util.asNode(nodeId).name AS Club,
       round(score, 6)              AS PageRankScore
ORDER BY PageRankScore DESC
LIMIT 10;

// Step 4: Drop projection
CALL gds.graph.drop('club-pagerank-graph');


// ============================================================
// GDS-2: Louvain Community Detection
// Louvain detects natural communities of clubs that trade heavily
// among themselves (e.g., league clusters, regional groups).
// Undirected orientation used — transfer connections are mutual.
// ============================================================

// Step 0: Drop old in-memory graph (safe on reruns)
CALL gds.graph.drop('club-louvain-graph', false);

// Step 1: Materialize directed Club->Club edges (seller -> buyer)
MATCH (seller:Club)<-[:FROM_CLUB]-(:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
MERGE (seller)-[:SOLD_TO]->(buyer);

// Step 2: Native projection — undirected Club-to-Club graph
CALL gds.graph.project(
  'club-louvain-graph',
  'Club',
  { SOLD_TO: { orientation: 'UNDIRECTED' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Step 3: Run Louvain — each club assigned a communityId
CALL gds.louvain.stream('club-louvain-graph')
YIELD nodeId, communityId
RETURN gds.util.asNode(nodeId).name AS Club,
       communityId                   AS Community
ORDER BY communityId ASC
LIMIT 20;

// Step 4: Count clubs per community (top communities by size)
CALL gds.louvain.stream('club-louvain-graph')
YIELD nodeId, communityId
RETURN communityId                                      AS Community,
       count(nodeId)                                    AS ClubsInCommunity,
       collect(gds.util.asNode(nodeId).name)[..5]       AS SampleClubs
ORDER BY ClubsInCommunity DESC
LIMIT 10;

// Step 5: Drop projection
CALL gds.graph.drop('club-louvain-graph');


// ============================================================
// GDS-3: Betweenness Centrality
// Clubs with high betweenness lie on many shortest transfer paths —
// they are critical connectors in the global transfer network.
// ============================================================

// Step 0: Drop old in-memory graph (safe on reruns)
CALL gds.graph.drop('club-betweenness-graph', false);

// Step 1: Materialize directed Club->Club edges (seller -> buyer)
MATCH (seller:Club)<-[:FROM_CLUB]-(:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
MERGE (seller)-[:SOLD_TO]->(buyer);

// Step 2: Native projection — directed Club-to-Club graph
CALL gds.graph.project(
  'club-betweenness-graph',
  'Club',
  { SOLD_TO: { orientation: 'NATURAL' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Step 3: Run Betweenness Centrality
CALL gds.betweenness.stream('club-betweenness-graph')
YIELD nodeId, score
RETURN gds.util.asNode(nodeId).name AS Club,
       round(score, 2)              AS BetweennessScore
ORDER BY BetweennessScore DESC
LIMIT 10;

// Step 4: Drop projection
CALL gds.graph.drop('club-betweenness-graph');


// ============================================================
// GDS-4: Weakly Connected Components (WCC)
// Finds groups of clubs that are reachable from each other through
// any sequence of transfer edges (ignoring direction).
// Tells us if the transfer network is one big connected component
// or fragmented into isolated regional clusters.
// ============================================================

// Step 0: Drop old in-memory graph (safe on reruns)
CALL gds.graph.drop('club-wcc-graph', false);

// Step 1: Materialize directed Club->Club edges (seller -> buyer)
MATCH (seller:Club)<-[:FROM_CLUB]-(:Transfer)-[:TO_CLUB]->(buyer:Club)
WHERE seller <> buyer
MERGE (seller)-[:SOLD_TO]->(buyer);

// Step 2: Native projection — undirected Club-to-Club graph
CALL gds.graph.project(
  'club-wcc-graph',
  'Club',
  { SOLD_TO: { orientation: 'UNDIRECTED' } }
)
YIELD graphName, nodeCount, relationshipCount;

// Step 3: Run WCC — clubs grouped by connected component
CALL gds.wcc.stream('club-wcc-graph')
YIELD nodeId, componentId
RETURN componentId                                      AS Component,
       count(nodeId)                                    AS ClubsInComponent,
       collect(gds.util.asNode(nodeId).name)[..5]       AS SampleClubs
ORDER BY ClubsInComponent DESC
LIMIT 10;

// Step 4: Drop projection
CALL gds.graph.drop('club-wcc-graph');


// ============================================================
// END OF MILESTONE 2 SCRIPT
// CS343 Graph Data Science - Spring 2026
// Muhammad Ammar Maqdoom & Ali Anwar
// ============================================================
