# cloudron-bluesky-pds

Bluesky maintains a [reference implementation](https://github.com/bluesky-social/atproto/tree/main/packages/pds) of an [AT Protocol PDS (Personal Data Server)](https://atproto.com/guides/the-at-stack#pds).  They also have [published a Docker image](https://github.com/bluesky-social/pds/pkgs/container/pds) for this PDS in the GitHub Container Registry.  Unfortunately this image won't work as-is in Cloudron.

Instead this project forks [bluesky-social/pds](https://github.com/bluesky-social/pds), the image source code project.  We pull in relevant upstream changes when possible.  Main differences:
1. Cloudron handles installation.  We don't need installer.sh which mostly sets up the host with Docker.
1. We can't use compose.yaml.  Cloudron only has support for dockerfile.
1. We don't need Caddy webserver.  Cloudron has a built in reverse proxy to map an app to a subdomain and handle inbound traffic.
1. Watchtower service won't be necessary either.  Cloudron handles application updates.

App version is pinned to the upstream project.

## Installation

Follow [these instructions](https://docs.cloudron.io/apps#community-app) to install this as a Community App (not reviewed by Cloudron) from the App Store.  

The URL to use for install:
```
https://raw.githubusercontent.com/sfeldkamp/cloudron-bluesky-pds/main/CloudronVersions.json
```

## Administration

Be aware that restarting the application or rebooting the Cloudron server will expire user PDS sessions and require them to login again.

Strongly recommend setting up a [secondary backup site](https://docs.cloudron.io/backups) at another storage provider other than your host.

### User Creation

To create a new user open the app web terminal and use the `goat` CLI.
```sh
  goat pds admin account create --handle newuser.location.domain.net --email new-user@email.com --password new-password
```

### User Registration

User self registration requires an invite code.  To create invite codes open the web terminal and use the `goat` CLI
```sh
  goat pds admin create-invites
```

:warning: It's not recommended to open the PDS for registration without an invite code at this time.  Tools for frustrating bots and monitoring abuse are still rather immature.

### User Migration

See [the atproto guide](https://atproto.com/guides/account-migration).


## Contributing

Fork this repository then see [App Packaging](https://docs.cloudron.io/packaging/) guidance.  Additional help is available in the [App Packaging and Developement forum](https://forum.cloudron.io/category/96/app-packaging-development).

Code for [Cloudron is hosted in Gitlab](https://git.cloudron.io/platform).
- [Cloudron Base Image documentation](https://git.cloudron.io/platform/docker-base-image).
- [Cloudron CLI](https://git.cloudron.io/platform/cloudron-cli)
- [Cloudron Box](https://git.cloudron.io/platform/box) is the code for the server.

Use the [local docker build workflow](https://docs.cloudron.io/packaging/tutorial#local-docker-build) since this app is published as a Custom App.  

General workflow is...
1. Make your changes
1. `cloudron build` to build in your local docker.
1. `cloudron install` to install the local docker image you built.  Choose a test location to install the app on your Cloudron server.
1. Make additional changes.  Then `cloudron build` then `cloudron update` to update the test location app.

Don't worry about publishing an image or adding a CloudronVersions.json entry.  I will take care of publishing the app after your changes are merged.

Submit a pull request.  You're welcome to send an email if I haven't seen it.

## Preparing a Release

1. Update version in CloudronManifiest.json (pin to Bluesky PDS version).
1. Then update CLOUDRON_CHANGELOG with the changes in version.
1. Then `cloudron build` to build the image locally and push to configured registry.
1. Then `cloudron versions add --state testing` for pre-release versions to update CloudronVersions.json.
1. Commit and push.
1. Install and test the app as a new app in a Cloudron server.
1. Update and test the app as an updated app in a Cloudron server.
1. Then `cloudron versions add` to release the update.  
1. Commit and push.

Cloudron users with the app installed will be notified of an update when the CloudronVersions.json file shows a new version is available (or the update may be applied automatically for them).

## License

This project is dual-licensed under MIT and Apache 2.0 terms:

- MIT license ([LICENSE-MIT.txt](https://github.com/sfeldkamp/cloudron-bluesky-pds/blob/main/LICENSE-MIT.txt) or http://opensource.org/licenses/MIT)
- Apache License, Version 2.0, ([LICENSE-APACHE.txt](https://github.com/sfeldkamp/cloudron-bluesky-pds/blob/main/LICENSE-APACHE.txt) or http://www.apache.org/licenses/LICENSE-2.0)

Downstream projects and end users may choose either license individually, or both together, at their discretion. The motivation for this dual-licensing is the additional software patent assurance provided by Apache 2.0.
