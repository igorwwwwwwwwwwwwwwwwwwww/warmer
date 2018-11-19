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

Warmer is a Sinatra app that runs in heroku. There are two ruby services that
run, `server` and `instance_checker`. There is also the redis instance that
maintains the lists of available warmed instances in each pool.

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

Make sure to keep git and heroku in sync. To actually **turn on** the warmer
service in staging, you will need to enable it with [trvs](https://github.com/travis-ci/trvs):

`trvs redis-cli travis-staging REDIS_URL set warmer.rollout.enabled 1`

(To turn the warmer off, run the same command without the `1` at the end.)

#### What's in the staging redis?

To see what's going on in redis, you can run:

`trvs redis-cli travis-staging REDIS_URL`

**Please note:** This redis instance is not just for warmer, and in fact is the live
redis for all of staging. If you want to test with a local redis, you can run
`redis-server` locally and change your `REDIS_URL` environment variable (to something
like `REDIS_URL=redis://localhost:6379`) and use just `redis-cli` to look at
keys and lists locally that way.

### Deploying to production

TODO

## Monitoring warmer

There are a couple different ways that you can check on the health of the Warmer
service.

- In the GCP console, you can look at how many instances with the `warmth:warmed`
label are running.

- Logs from heroku can be viewed with `heroku logs --tail`.

- Check which heroku processes are running with `heroku ps`. You can change how
many processes are supposed to be running from the command line with the `ps:scale`
command, such as `heroku ps:scale web=0`. 
