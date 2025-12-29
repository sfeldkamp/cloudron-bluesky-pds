# cloudron-bluesky-pds

This project packages a [Bluesky Personal Data Server](https://github.com/bluesky-social/pds) for installation on [Cloudron](https://www.cloudron.io/).

## Cloudron Apps
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

## Bluesky PDS
[Bluesky PDS](https://github.com/bluesky-social/pds) is a thin project whose main file is installer.sh. When run this creates the Bluesky PDS from assets in the repo and also from code downloaded from the main [ATProto repositor PDS package](https://github.com/bluesky-social/atproto/tree/main/packages/pds).  

Some differences between this fork and the upstream project:
1. We can't use compose.yaml.  Cloudron only has support for dockerfile.
1. We don't need Caddy webserver.  Cloudron maps an app to a subdomain and handles inbound traffic.
1. Watchtower service won't be necessary either.  Cloudron handles application updates.