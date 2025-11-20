# Ubicloud Mastodon Demo

a.k.a. "ubidon"

See the slides and source code for this talk at
https://github.com/ubicloud/ubidon

Getting out your laptop or phone to skim source or speaker notes
is encouraged!

---

## What is Ubicloud?

- **Almost all [open source Ruby](https://github.com/ubicloud/ubicloud)**
- Ubicloud is an open-source IaaS
- Think AWS, Azure, GCP
- Source: github.com/ubicloud/ubicloud
- Mostly it is a **public cloud**
- We started it because we felt the hyperscalers were charging too much
- We also like to put the code to work through private cloud, too
  - contact us for this, these tend to be more complex

???

- Welcome everyone. Today I'm going present to you a demonstration of
  Ubicloud.

- Ubicloud an open-source infrastructure cloud: think load balancers, virtual
  machines databases, etc. As a shorthand, we refer to ourselves as an
  open-source alternative to AWS.

- The demonstration is a script that sets up non-trivial web
  application, an instance of Mastodon, which has Rails and Node
  components.

- On the name of the company: "Ubi" is a contraction of "ubiquitous",
  as we have obligations to portability and being able to run in
  diverse environments.

- Now that you have a sense of the company's purpose, let me start this
  demo script, so it can run in the background.

- **START ubidon-provision.bash NOW**

- Now that that has started, and we've seen it quickly move through
  making resources in Ubicloud, I'll multitask by discussing some
  aspects of Ubicloud's implementation.

---

## On Reading the Code

- Given it's a Ruby Conference it's ≈ all Ruby...
- ≈ 85,000 physical LOC, ≈ 50% of it is tests
- 100% branch coverage
- Not Rails
  - But not in *reaction* to Rails...rather, my Ruby work never intersected with
    Rails
  - People find that weird and entertaining, so I mention it.

???

- Of special interest to this crowd is Ubicloud being written in Ruby:
  85,000 physical source lines, and about 50% is tests.

- With its small size, and generally detailed commit messages, I
  encourage you to get a copy of the source and look around.

- It has 100% branch coverage, so getting tests passing for a change
  is a decent model of correctness.

- Due to a quirk of history, not only is the code not Rails, but it
  has no direct influence from Rails because the engineering team has
  had minimal contact with Rails, even if they have substantial Ruby
  experience.

- I mention this because, you might read this and see something
  interesting, or different.  I'm just trying to get you into the
  source code.

- Do we get good feature economy for our lines of code? You be the judge. I like
  to think so. It is among the reasons we use Ruby.

---

## On Mastodon

- A federated microblogging platform
- written with Rails
- there are some websocket-dependent features
- it is in production across the world

???

- Many of you are at least passingly familiar with Mastodon.
- It's a federated microblogging implementation written using Rails
- It looks nice, it has a mobile app, try it out one of these days.
- But, fewer of you are familiar with its major components, which
  inform how to organize it in any cloud, including Ubicloud.

---

## Mastodon, its process types and dependencies

- It has three process types: `web`, `streaming`, `sidekiq`
- `web` and `streaming` need HTTPS / Port 443 and load balancers
- `sidekiq` doesn't need to listen to anything
- All processes need Redis and Postgres dependency: Port 6379, 5432

???

Mastodon has three kinds of processes with different, interlocking
network dependencies.

One of the dependencies, valkey, I host on a regular VM: it is not
exposed to the Internet, but must make valkey available to all of
mastodon's process types.

The Postgres dependency is fulfilled using Ubicloud's managed Postgres
service.

Of Mastodon's three processes, only two need to listen on any ports,
and both of those are to serve a browser.

---

## What `ubidon-provision.bash` Builds

- A multi-VM Mastodon instance
- Rich firewall and multi-VM organization by type
- Load balancing, TLS, WebSockets
- All deployed and configured automatically using the CLI
  - Did you attend/review Jeremy Evans's talk?
  - The way the CLI works inside is quite unusual.
  - But it looks completely normal in the shell script.
  - You should check it out.

???

- The script I ran at the beginning of the talk, in just a few
  seconds, organized Mastodon in Ubicloud.
- ...and I want to discuss some of the principles of that organization.
- The way we'll understand the organization is via networking
  constructs.
- Networking data models is an area where every hyperscaler cloud is
  subtly distinct from the others.
- Ubicloud, likewise, proposes its own ideas about how to organize
  networks and what is inside them.

---

# On Firewalls & Subnets

- Subnets compose zero or more firewalls.
- Subnets catenate the ruleset, apply uniformly
- Firewalls factor out sets of rules.
- There are no firewalls on individual VMs

| Subnet        | Firewalls                         |
| ------------- | --------------------------------- |
| valkey-subnet | ssh-internet-fw,valkey-fw         |
| sidekiq       | ssh-internet-fw                   |
| web,streaming | ssh-internet-fw,https-internet-fw |

- Easy to connect subnets together, like a lightweight peering
- This makes no-individual-VM-firewalls usable

???
- The most important organizing objects in Ubicloud are Subnets and Firewalls.
- Firewalls allow composition of rules, such as "port 22 from
  internet" for secure shell, and independently, "https for a web
  server"
- Subnets apply zero or more firewalls uniformly to every VM inside
- There is no per-VM firewall!
- Seen in the table are the firewalls and subnets I chose for Mastodon
  - You can see every subnet lets me use secure shell
  - sidekiq's worker subnet *only* listens to let me use secure shell
  - But `web` and `streaming` allow HTTPS...
  - Valkey has its own firewall rule. It contains references to all
    the application subnets...and *not* the Internet.
- Ubicloud's design theory is subnets, being *contiguous* IP address
  space is deeply related to how firewalls work...
  - how efficient they are
  - what quotas we must impose on their complexity
- Other firewall management approaches that explode into many non-contiguous
  addresses impose abstraction leaks to the customer in performance, cost, and
  quota complexity.
- In exchange, we try to make subnets easy to create and connect
  together, even if a subnet has a single VM sometimes.
- Under the hood: all private subnet traffic is encrypted: use of TLS
  is "belt and suspenders," but you could omit it.

---

## Demo Check: is `ubidon-provision.bash` done?

Adding a Mastodon `relay` can take a few minutes to liven up, so let's add it
and continue.

---

## Load Balancing: another revisionist area

- In our example, just one VM per load balancer
- They help with TLS, with a twist
- Key material is made available to your instance:
```
http://[FD00:0B1C:100D:5afe:CE::]/load-balancer/key.pem
http://[FD00:0B1C:100D:5afe:CE::]/load-balancer/cert.pem
```
- We don't terminate TLS, but we can make it easy for *you* to terminate it
- `ubidon-provision.bash` sets up a timed script that refreshes certificates.

???

Load balancers are another area we have reinterpred some well-known
techniques to offer something portable, convenient, and inexpensive.

We implement a DNS based load balancer.  Because the load balancer
uses DNS, we can do a tiny bit more work to optionally solve an ACME
DNS01 challenge for you with ZeroSSL/LetsEncrypt.

The certificate key material is made available to your application via
a metadata endpoint.

The mastodon demo script sets up a timer to refresh these certificates
every day.


---


## Load Balancing: details

- Is DNS + Linux `nftables` based
- Low overhead
- Zero marginal dollar cost
- General to all TCP
- That's why WebSockets has zero ceremony: we don't do anything to get in the way!
- Can use it directly on application nodes, as we do in this demo
- Can compose well with dedicated subnets filled with your preferred proxy:
  - nginx, traefik, envoy, etc
  - for path routing, caching, header rewriting, session affinity, whatever
- Intended for production use as an "origin" or "upstream" for CDNs/WAFs

???

We do things this way so we can use `nftables` to provide a Layer 4
load balancer.

Load balancers of this type have the benefit of low overhead and
excellent composition with all sorts of protocols: that's why
websockets, or even a load balanced SSH pool, can work without a fuss.

We embed these nftables rules at the host level along with your
virtual machine.  This is why they have zero additional cost to you.

The downside of a layer 4 load balancer is their flexibility is
limited, and most importantly, they can't terminate TLS, pushing a
painful secret management experience onto the simplest deployments.
That's why we made it easy for you to terminate TLS yourself.

These load balancers make good "origins" or "upstreams" for web
application firewalls or a CDN.

---


## Let's visit the Demo

* Did I get some relay stuff?
* Can we see web socket is active?
* How about clicking through to sidekiq and pghero?

---


## End Notes

- Ubicloud: it's written in Ruby.
- It's open source
- Read the source!
- It can run, organize, and secure a non-trivial Rails application
- We focus on fair pricing, privacy, portability, security
- Use it on the public cloud, send us your comments!
- For private cloud: if you want to organize a few-to-many cabinets of physical servers with Ubicloud, contact us
- **Come by and say hi and talk shop about infrastructure for fun**
- THANK YOU
