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

- Welcome everyone. Today I'm going to give you a demo of Ubicloud, setting up a
  non-trivial web application, an instance of Mastodon, which has Rails and Node
  components.

- Ubicloud an open-source infrastructure cloud: think load balancers, virtual
  machines databases, etc. As a shorthand, we refer to ourselves as an
  open-source alternative to AWS.

- On the name: "Ubi": the "ubiquitous" infrastructure cloud, as we have
  obligations to portability and being able to run in diverse environments.

- Now that you have a sense of the company, let me start this demo script, so it
  can run.

- **START ubidon-provision.bash NOW**

- In a few seconds, all the Ubicloud networking, database, and VM arrangements
  will be done, then it's mostly waiting on Linux/Docker stuff.

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

- Of special interest to this crowd is the bulk of the code is in Ruby: 85,000
  physical source lines, about 50% of the length is tests.

- The commit messages are generally detailed.

- Due to a quirk of history, not only is the code not Rails, but it has no
  direct influence from Rails because the contact the engineering team has had
  with Rails, even in the past, is minimal to none.

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
- It looks nice, it has a mobile app, try it out one of these days.
- Fewer of you are familiar with its major components and administration
  features

---

## Mastodon, its process types and dependencies

- It has three process types: `web`, `streaming`, `sidekiq`
- `web` and `streaming` need HTTPS / Port 443 and load balancers
- `sidekiq` doesn't need to listen to anything
- All processes need Redis and Postgres dependency: Port 6379, 5432

???

Important thing to note here: three kinds of processes with different,
interlocking network dependencies.

One of the dependencies, valkey, I host on a regular VM

The Postgres dependency is fulfilled using Ubicloud's cloud managed version.

A number of the staff and myself got our control plane experience writing and
operating cloud Postgres services, so cloud Postgres is one of our more advanced
features.

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

- So what's this script I ran at the beginning the talk?
- It organizes the dependencies and process types of Mastodon as intended by the
  designers of Ubicloud.
- By glancing at the web site from what it created, you will be more familiar
  with how things "should" look.
- I'll discuss some data models in the networking stack: they are both key to
  how to organize and secure services for an application, and in detail, among
  the least consistent implementations among cloud providers.
- For example: AWS Subnets are zonal, unlike Azure, GCP, and Oracle Cloud, this
  has deep ramifications.
- There are other differences that all the clouds have with one another, their
  consequences fill a stand-alone talk.
- Though were I to present it, it would bore you to tears.
- We introduced yet another way of doing things, but hopefully we came up with
  something nice...said every designer at the time.

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

- Subnet & Firewall ideas in general:
  - Firewall entities allow factoring/reuse of rule sets
  - Firewalls are conventional, being additive lists of allow-rules.
  - But subnets are less conventional:
  - Subnets apply zero or more firewalls uniformly to every VM inside
  - There is no per-VM firewall!
- Seen in the table are exact identifiers seen in the provision script.
  - You can see every subnet lets me use SSH for this demo
  - sidekiq *only* listens on SSH for the demo...
  - But only some allow HTTP...
  - Valkey has its own firewall rule. It contains references to all
    the application subnets...and *not* the Internet.
- Ubicloud's design theory: subnets, being *contiguous* IP address
  space is deeply related to how firewalls work...
  - how efficient they are
  - what quotas we must impose
- Other firewall management approaches that explode into many non-contiguous
  addresses impose abstraction leaks to the customer in performance, cost, and
  quota complexity.
- In exchange, we try to make subnets easy to create and connect together to
  build your apps, and de-emphasize one-off firewall rules on VMs that are in
  mixed company in one address space.
- We're working on making this conceit work great for our managed services and
  third party managed services, because if you ever offered a managed service
  where the customer base cared about firewalls on the big platforms, you know
  how troublesome this can be!
- Under the hood: all inter-subnet traffic is dual-stacked with IPv6 and IPv4,
  and encrypted, since we are often working on networks of varying security and
  physical robustness.
- Aside on encryption: all disks are likewise encrypted.

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
  - for path routing, caching, header rewriting, whatever


---


## Let's visit the Demo

* Did I get some relay stuff?
* Can we see web socket is active?
* How about clicking through to sidekiq and pghero?


---


## End Notes

- Ubicloud: it's written in Ruby. You can read the source!
- It can run, organize, and secure a non-trivial Rails application
- We focus on low costs
- It has managed Postgres
- It also has a popular, and extremely
- It's portable: if you want to organize a few cabinets of bare metal with Ubicloud, contact us
```
