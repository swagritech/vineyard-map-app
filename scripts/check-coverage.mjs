// NDVI coverage report (informational only). Node helper for the import wizard
// (docs/WIZARD_SPEC.md §6.4). Loads a customer's vineyard.json + boundaries file +
// each survey's rx file and reports which drawn blocks each NDVI flight covers,
// using the SAME rep-point + point-in-polygon algorithm as docs/V2_DESIGN.md §4.6
// and index.html (code shapes copied verbatim; see index.html's repPoints /
// computeBlockSurveyLinks / pointInRing / pointInPolygon / pointInGeom).
//
// Usage: node scripts/check-coverage.mjs <repoRoot> <Customer>
//
// No dependencies. Plain console.log. Always exits 0 - this is a warnings-only
// report, never a build/test failure.

import fs from "node:fs";
import path from "node:path";

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

// Representative point per polygon PART = vertex average of its outer ring.
// (V2_DESIGN.md §4.6, copied verbatim.) GeoJSON coords are [lng, lat].
function repPoints(g) {
  const polys = g.type === "Polygon" ? [g.coordinates] : g.coordinates;
  return polys.map(rings => {
    const ring = rings[0];
    let sx = 0, sy = 0;
    for (const c of ring) { sx += c[0]; sy += c[1]; }
    return [sx / ring.length, sy / ring.length];
  });
}

// ---------------------------
// Point in polygon (copied verbatim from index.html)
// ---------------------------
function pointInRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1];
    const xj = ring[j][0], yj = ring[j][1];
    const intersect =
      ((yi > y) !== (yj > y)) &&
      (x < (xj - xi) * (y - yi) / ((yj - yi) || 1e-12) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

function pointInPolygon(x, y, rings) {
  if (!rings || rings.length === 0) return false;
  if (!pointInRing(x, y, rings[0])) return false;
  for (let h = 1; h < rings.length; h++) {
    if (pointInRing(x, y, rings[h])) return false;
  }
  return true;
}

function pointInGeom(x, y, geom) {
  if (!geom) return false;
  if (geom.type === "Polygon") return pointInPolygon(x, y, geom.coordinates);
  if (geom.type === "MultiPolygon") return geom.coordinates.some(p => pointInPolygon(x, y, p));
  return false;
}

// Spatial block<->survey links (§4.6): survey s covers block b iff ANY rep point
// of ANY part of ANY of s's rx features lands inside b's geometry.
// blockGeomList: [{key, geom}]; surveyRx: [{surveyId, features:[{geometry}]}].
// NEVER name/number-based. Returns { blockKey: [surveyId,...] } in survey order.
function computeBlockSurveyLinks(blockGeomList, surveyRx) {
  const links = {};
  for (const b of blockGeomList) {
    links[b.key] = [];
    for (const s of surveyRx) {
      const covers = (s.features || []).some(f =>
        f && f.geometry && repPoints(f.geometry).some(p => pointInGeom(p[0], p[1], b.geom))
      );
      if (covers) links[b.key].push(String(s.surveyId));
    }
  }
  return links;
}

function main() {
  const repoRoot = process.argv[2];
  const customer = process.argv[3];

  if (!repoRoot || !customer) {
    console.log("Usage: node check-coverage.mjs <repoRoot> <Customer>");
    return;
  }

  const customerRoot = path.join(repoRoot, "customers", customer);
  const vineyardPath = path.join(customerRoot, "vineyard.json");
  if (!fs.existsSync(vineyardPath)) {
    return;
  }

  const manifest = readJson(vineyardPath);
  if (!manifest.boundaries) {
    return;
  }

  const boundaryPath = path.join(customerRoot, manifest.boundaries);
  if (!fs.existsSync(boundaryPath)) {
    return;
  }
  const boundaryJson = readJson(boundaryPath);
  const boundaryFeatures = boundaryJson.features || [];

  // Match boundary features to manifest blocks by featureName (index.html §5.3:
  // "match feature's name property to blocks[].featureName").
  const blockGeomList = [];
  for (const block of manifest.blocks || []) {
    const feature = boundaryFeatures.find(
      f => f && f.properties && f.properties.name === block.featureName
    );
    if (feature && feature.geometry) {
      blockGeomList.push({ key: block.key, geom: feature.geometry });
    }
  }

  // Load each survey's rx features.
  const surveyRx = [];
  for (const survey of manifest.surveys || []) {
    const rxPath = path.join(customerRoot, survey.rx);
    if (!fs.existsSync(rxPath)) continue;
    const rxJson = readJson(rxPath);
    surveyRx.push({ surveyId: survey.token, features: rxJson.features || [] });
  }

  const links = computeBlockSurveyLinks(blockGeomList, surveyRx);

  console.log(`NDVI coverage for ${manifest.customer}:`);

  const rows = (manifest.blocks || []).map(block => {
    const label = block.variety ? `${block.displayName} (${block.variety})` : block.displayName;
    return { block, label };
  });
  const width = rows.reduce((m, r) => Math.max(m, r.label.length), 0);

  const coveredTokens = new Set();
  for (const { block, label } of rows) {
    const tokens = links[block.key] || [];
    tokens.forEach(t => coveredTokens.add(t));
    const rhs = tokens.length > 0 ? tokens.join(", ") : "(no NDVI flight covers this block)";
    console.log(`  ${label.padEnd(width)}  <- ${rhs}`);
  }

  for (const s of surveyRx) {
    if (!coveredTokens.has(s.surveyId)) {
      console.log(`  Flight ${s.surveyId}: covers no drawn block`);
    }
  }
}

// No explicit process.exit() calls anywhere above (or here): on Windows,
// stdout to a redirected/piped destination is asynchronous, and process.exit()
// can truncate still-buffered console.log output before it flushes. Letting
// the script run to completion and exit naturally (always 0, since we catch
// everything below - warnings are not errors) avoids losing output when the
// wizard invokes this as a child process.
try {
  main();
} catch (err) {
  console.log(`(coverage check error: ${err && err.message ? err.message : err})`);
}
