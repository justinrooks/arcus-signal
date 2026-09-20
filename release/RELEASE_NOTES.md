# Release Notes

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
