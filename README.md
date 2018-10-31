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
returned to worker and subsequently removed from the pool.

There is one pool per image name.

## How is it deployed/where does it run?

Warmer runs in heroku. There are two ruby services that run, `server` and
`instance_checker`. There is also the redis instance that maintains the lists
of available warmed instances in each pool.

## How can I test it?

Warmer runs in both staging and production. It can also be tested locally to a
certain extent.

### Testing locally

Make sure you have local environment variables set up. Examples of what env vars
need to be set can be found in `example.env`. (The secrets can be found in the
heroku config currently running.) You will want to make sure you have the
staging project set:

`export GOOGLE_CLOUD_PROJECT=travis-staging-1`

If you haven't already, make sure to run `bundle`. You can then run locally the
service you want to test. For example:

`ruby server.rb`

### Testing on staging

To test on staging, you will first want to add staging as a git remote for
convenience. (Make sure you have the [heroku cli](https://devcenter.heroku.com/articles/heroku-cli)
installed first.)

`heroku git:remote -a travis-warmer-staging-1`

You will also want to make sure to have the staging project set (along with the
rest of the env vars described in the local testing section):

`export GOOGLE_CLOUD_PROJECT=travis-staging-1`

When your changes are ready to be deployed to staging, they can be deployed by running:

`git push heroku your-cool-staging-branch-name`

Make sure to keep git and heroku in sync.

#### What's in the staging redis?

TODO

### Deploying to production

TODO
