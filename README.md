# cloudron-bluesky-pds

This project packages an [ATProto Personal Data Server (Bluesky implementation)](https://github.com/bluesky-social/pds) for installation on [Cloudron](https://www.cloudron.io/).

## Requirements

The root domain mapped to the Cloudron Bluesky PDS app must have a wildcard certificate associated with it since user accounts are identified by subdomain and user identity can be validated through the `./well-known/atproto-did` path.  If it is not you may see either the DID output or an `Invalid Handle` warning instead of your preferred display name.

1. Ensure the domain's DNS Provider is a provider with an API integration.
2. Ensure the option _Let's Encrypt Prod - Wildcard_ is selected as the Certificate Provider.
3. Add _Alias_ to the app under _Location_.  Configure with an alias of `*.[app.domain.com]`.

It takes some time for DNS to propagate so be patient.

## Installation

Install the app from the Cloudron app store if possible.  If not you can build this project as a docker image and install as a custom app in Cloudron using the Cloudron CLI.

:warning After installation configure the app location to add an alias like `*.[app.domain.com]`.  This is necessary for the account handle verification to work correctly.

## Usage

A PDS doesn't have any web GUI. If you browse to the app domain, you'll just see some ASCII art confirming the server exists.


### Migrating An Account

It possible for this to go wrong and get stuck in the middle.  I recommend you try this with a test account first, before committing to migrating your main account.

:warning If something does go wrong you are completely on your own to fix it.


1. Create an invite code.
`goat pds admin create-invites`.

2. Migrate account using either of these two options.
Read through [these instructions](https://whtwnd.com/bnewbold.net/3l5ii332pf32u).  Then follow the steps in Automatic Account Migration.  Run the `goat` commands using the web terminal within the app container.  Another options is [PDS Moover](https://pdsmoover.com/).


### Create A New Account

If you want a brand new account you can create one using the Bluesky App.

1. In Cloudron Bluesky PDS web terminal run `goat pds admin create-invites`.  Copy the invite code.
2. In Bluesky App (or other ATProto client) go through the Add Account flow.  First switch the domain to the Cloudron Bluesky PDS domain.
3. Then enter the details of the new account.


## Contributing

This project will only live on if Cloudron declines to put the app image in the App Store.  In that case fork, develop and submit a PR from your repo to main branch.

### Cloudron Apps
Packaged apps are deployed to Docker containers on the Cloudron server.  During development this is done with the [Cloudron CLI](https://docs.cloudron.io/packaging/cli/).

- [Tutorial](https://docs.cloudron.io/packaging/tutorial/)
- [Cheat Sheet](https://docs.cloudron.io/packaging/cheat-sheet/)
- [Addons](https://docs.cloudron.io/packaging/addons/)
- [Manifest](https://docs.cloudron.io/packaging/manifest/)
- [Publishing](https://docs.cloudron.io/packaging/publishing/)

Additional help is available in the [App Packaging and Developement forum](https://forum.cloudron.io/category/96/app-packaging-development).


Code for [Cloudron is hosted in Gitlab](https://git.cloudron.io/platform).
- [Cloudron Base Image documentation](https://git.cloudron.io/platform/docker-base-image).
- [Cloudron CLI](https://git.cloudron.io/platform/cloudron-cli)
- [Cloudron Box](https://git.cloudron.io/platform/box) is the code for the server.

### Bluesky PDS
[Bluesky PDS](https://github.com/bluesky-social/pds) is a thin project with a few purposes.

 1. An installer.sh file that prepares a VPS host that installs dependencies (including docker), downloads image, and composes the docker container services.
 1. A workflow that publishes a docker image to GitHub Container Registry.
 1. The pdsadmin cli for managing the app.

When run this creates the Bluesky PDS from assets in the repo and also from code downloaded from the main [ATProto repositor PDS package](https://github.com/bluesky-social/atproto/tree/main/packages/pds).  

Some differences between this fork and the upstream project:
1. We can't use compose.yaml.  Cloudron only has support for dockerfile.
1. We don't need Caddy webserver.  Cloudron maps an app to a subdomain and configures proxy for inbound traffic.
1. Watchtower service won't be necessary either.  Cloudron handles application updates.

Files related to these items have been removed from this fork of the [Bluesky PDS](https://github.com/bluesky-social/pds).