# Architecture — msp-httpbin-operator

This document describes the architecture of the HttpBin MSP example.

## Overview

```mermaid
flowchart TB
    subgraph kcp["kcp (control plane)"]
        subgraph provider["Provider Workspace<br/>root:msp:httpbin-provider"]
            APIExport["APIExport<br/>api-syncagent"]
        end
        subgraph consumer["Consumer Workspace<br/>root:msp:customer-a"]
            APIBinding["APIBinding<br/>→ api-syncagent"]
            HttpBinOrder["HttpBin<br/>httpbin-demo"]
        end
    end

    subgraph kind["kind cluster (service cluster)"]
        subgraph kcpsystem["kcp-system namespace"]
            SyncAgent["api-syncagent<br/>(deployment)"]
        end
        subgraph httpbinsystem["httpbin-system namespace"]
            Operator["httpbin-operator<br/>(deployment)"]
        end
        subgraph default["default namespace"]
            HttpBinCR["HttpBin CR<br/>(synced)"]
            Deploy["Deployment<br/>httpbin-demo"]
            Service["Service<br/>httpbin-demo"]
            Pod["Pod<br/>kennethreitz/httpbin"]
        end
    end

    %% Relationships
    APIBinding -->|binds to| APIExport
    HttpBinOrder -->|"sync DOWN"| SyncAgent
    SyncAgent -->|creates| HttpBinCR
    HttpBinCR -->|watched by| Operator
    Operator -->|creates| Deploy
    Operator -->|creates| Service
    Deploy -->|runs| Pod
    Service -->|exposes| Pod
    HttpBinCR -->|"sync UP (status)"| SyncAgent
    SyncAgent -->|updates| HttpBinOrder

    style kcp fill:#e1f5fe
    style kind fill:#fff3e0
    style HttpBinOrder fill:#c8e6c9
    style HttpBinCR fill:#c8e6c9
```

## Flow

1. **Consumer orders an HttpBin** — The consumer creates an `HttpBin` CR in their kcp workspace (`root:msp:customer-a`).

2. **api-syncagent syncs DOWN** — The agent (running in kind) watches the consumer workspace via the `APIBinding`. When it sees the new `HttpBin`, it creates a corresponding `HttpBin` CR in the kind cluster.

3. **httpbin-operator provisions resources** — The operator (running in kind) watches for `HttpBin` CRs. When it sees one, it creates:
   - A `Deployment` running the `kennethreitz/httpbin` container
   - A `Service` exposing the deployment

4. **Status syncs UP** — The operator updates the `HttpBin` CR's `.status` (ready, url). The api-syncagent syncs this status back to the consumer's `HttpBin` in kcp.

5. **Consumer sees ready state** — The consumer can now see their HttpBin is ready and get the service URL.

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| kcp | Host process | Control plane — hosts workspaces, APIExports, APIBindings |
| api-syncagent | kind / kcp-system | Syncs objects between kcp workspaces and the kind cluster |
| httpbin-operator | kind / httpbin-system | Watches HttpBin CRs, creates Deployments + Services |
| HttpBin CRD | kind | Defines the HttpBin custom resource |

## Key Differences from msp-postgres-kcp-only

| Aspect | msp-postgres-kcp-only | msp-httpbin-operator |
|--------|----------------------|---------------------|
| Backing operator | CloudNativePG (third-party) | Custom httpbin-operator |
| API passthrough | CNPG's native `Cluster` API | Custom `HttpBin` API |
| Related resources | Connection Secret syncs back | No related resources |
| Complexity | Higher (stateful database) | Lower (stateless httpbin) |
