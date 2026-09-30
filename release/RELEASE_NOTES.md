# Release Notes

## v1.1.0

## Overview

Arcus Signal v1.1.0 strengthens notification dispatch and pressure-artifact cleanup while expanding operator health and delivery diagnostics. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- Notification outbox dispatch now uses atomic claims and lease fencing to recover safely from concurrent workers and queue-handoff failures.
- Pressure-artifact processing protects worker-claimed and completed records from late probe failures, and cleanup removes eligible terminal catalog records after 60 days.
- Operator dashboard freshness thresholds now match each page: three minutes for Overview and fifteen minutes for Model Pipeline and other detail pages.
- Ingest freshness now distinguishes healthy, delayed, and unknown states using the last successful sweep, with a 105-second healthy threshold.
- Delivery diagnostics show the 30 newest notification attempts with details inline and All / Targeted / Preview filters that remain selected during live refresh.

## v1.0.0

## Overview

Arcus Signal v1.0.0 establishes the server-side severe-weather alert pipeline, including NWS ingestion, durable revision and notification processing, location-aware targeting, Storm Setup data workflows, operator diagnostics, and explicit versioned container deployment.

## Highlights

- NWS alerts now flow through durable ingestion, revision, geospatial targeting, outbox, and notification-delivery boundaries.
- The server provides canonical `/v1` APIs for alerts, device presence and preferences, location snapshots, and operator diagnostics while preserving the documented compatibility routes.
- Storm Setup processing includes HRRR surface and pressure-artifact workflows, tornado viability analysis, and AirNow AQI data.
- Notification delivery includes installation-scoped targeting, freshness-aware presence reconciliation, durable ledger protection, bounded retries, and replay-safe processing.
- The operator dashboard reports health state, alert and installation activity, delivery context, responsive layouts, and the deployed Arcus Signal release version.
- Stable GitHub Releases now define the production container build boundary; the installer deploys an explicitly selected version to both API and worker services.

## Maintenance

- Architecture, endpoint, Postman, operational, rollout-readiness, and release documentation were updated alongside the implementation work.
