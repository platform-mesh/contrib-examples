# Architecture — IronCore ManagedServiceProvider (MSP) with Platform-Mesh

This variant turns **IronCore compute and networking resources** into orderable services on the Platform Mesh, with a KCP provider workspace (as pure **data plane**). A consumer creates IronCore resources (Machine, Network, VirtualIP,NetworkInterface, ..) in their own account workspace; the kcp **api-syncagent** — running in the ironcore-in-a-box
cluster and dialling *outbound* to Platform-Mesh's KCP system — syncs them down, where the **IronCore controllers**
provision real VMs and overlay networks. Status flows back up to the consumer workspace. 

## Pinned, matched stack
- **KCP** — provided by Platform-Mesh; not a host binary here.
- **api-syncagent** (targets KCP; Helm chart `kcp/api-syncagent`) — running in the
  IronCore-in-a-box cluster.
- **IronCore-in-a-box** — sample IronCore stack: ironcore controllers, ironcore-net, apinetlet, libvirt-provider, dpservice, metalnet, metalnetlet, metalbond.

## Published Resources

| API Group | Kind | Version | Description |
|---|---|---|---|
| `compute.ironcore.dev` | Machine | v1alpha1 | Virtual machines with configurable machine classes |
| `networking.ironcore.dev` | Network | v1alpha1 | Overlay / VPC networks |
| `networking.ironcore.dev` | VirtualIP | v1alpha1 | Public virtual IPs |
| `networking.ironcore.dev` | NetworkInterface | v1alpha1 | NICs connecting machines to networks |
