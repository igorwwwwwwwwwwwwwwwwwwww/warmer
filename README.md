# warmer

The warmer is a service that maintains pools of already running or pre-warmed
VMs. This allows for customer jobs to start running sooner, since they will not
have to wait for a new VM to boot from scratch.

## How does it work?

At a high level, the service checks how many pre-warmed VMs are currently running
and compares that to a configured number of pre-warmed VMs that _should_ be
running. If there are fewer than the desired number currently running, more
VMs are booted and added to the pool until that number is reached.

A list of pre-warmed instances in the pool is stored in Redis. When worker
needs to start running a customer job, it requests an instance from warmer. If
warmed VMs are available in the pool, the IP address of the oldest one is
returned to worker and subsequently removed from the pool. There is one pool per
image name.

## How do we operate it?

If you need to know this, you probably want the internal runbook!
