---
layout: post
comments: true
title: Docker pitfalls
---

Containers have been really trendy recently and I can certainly agree that they are changing the world of software delivery. Although the overall idea of putting applications inside immutable containers is not new, Docker is the first widely adopted implementation which makes it easy as a snap. Containerization has multiple benefits but the most important one (in my opinion) - it makes software easily deployable and therefore scalable.

Unfortunately, a path to immutability and scalability is pretty rough and Docker is way too far from being a solution to all infrastructure problems. In fact, Docker even introduces a few of them.

## Package installation hell

Have you ever worked with Ruby on Rails applications which are larger than hello world websites? Usually, they depend on a few dozen gems which are listed in Gemfile. Installing everything from scratch takes quite a few time - bundler needs to download gems from rubygems.org and compile those with  native extensions.

Welcome to the Docker world. You can no longer rely on host machine having all the dependencies you need. You have to put all application dependencies inside the container because this is what makes your application deployable. Of course, Docker can do it for you:

    ADD . /app/
    RUN bundle install

This approach has one big caveat - whenever any file inside your app directory changes, docker will invalidate the `ADD . /app` image cache and cache for all subsequent commands including `RUN bundle install`. It means whenever you will be changing your app code, you have to re-install bundle from scratch. Of course, there is one pretty nice technique to avoid this problem:

    ADD Gemfile /app/
    ADD Gemfile.lock /app/
    RUN bundle install

    ADD . /app/

This will ensure that Docker will only invalidate `RUN bundle install` cache whenever either Gemfile or Gemfile.lock is changed. It partially solves the problem, but when you need to add a new gem to the Gemfile or update one of the existing, Docker still has to re-install everything from scratch. It dramatically affects image build time and can be very annoying, especially if you use Docker for development. Which you should do, because you want your development environment to be as close to production as possible. It also affects build time on Continuous Integration server.

### Install at the runtime

One way of fixing it is to do `bundle install` during container runtime before starting rails server. You can run custom shell script in `CMD` in your `Dockerfile`.

Dockerfile:

    COPY start.sh /
    CMD /start.sh

start.sh:

{% highlight bash %}
#!/bin/bash

set -e

bundle check || bundle install
exec bundle exec rails server
{% endhighlight %}

It will check if the bundle is installed and will install it otherwise. Then it will start rails server. You can also set `GEM_HOME` environment variable to some well-known location and mount it as a host volume so that you don't have to re-install everything from scratch every time.

There's one disadvantage in this approach - your container now depends on the host system and it loads all dependencies dynamically from host volume. It's generally not a problem on Linux systems, but on Mac, volume mount can be pretty slow. More about it later.

### Build time volumes with rocker

Another possible solution for this problem is build time volumes. Docker does not allow to mount volumes during the build time, but there's a tool called [rocker] which extends Docker with this feature (and a few others). Below is an example how it can be achieved with rocker:

Rockerfile:

    ENV GEM_HOME /volume-gems
    ENV PATH $PATH:$GEM_HOME/bin
    MOUNT /volume-gems

    RUN gem install bundler --no-ri --no-rdoc

    ADD Gemfile $dir/
    ADD Gemfile.lock $dir/
    RUN bundle install

    ENV GEM_HOME /gems
    ENV PATH $PATH:$GEM_HOME/bin
    RUN cp -R /volume-gems /gems

First, it creates a volume container and mounts `/volume-gems` directory from it. It also tells `bundler` to use it as a gem installation path (by setting `GEM_HOME` environment variable). Then all gems are getting installed into this directory. Next step is to switch gem directory to `/gems` which is a part of container file system. An entire `/volume-gems` directory is copied to `/gems` so that app has all the dependencies inside the container. This speeds up bundle installation at the cost of time needed to copy everything from volume mount to the container, but it usually takes much less time.

## Docker for Mac Beta (Betta then nothing, huh?)

Docker for Mac Beta introduces a new shiny way to use docker. Previously, you had to install Docker virtual machine in VirtualBox. You don't have to do it now, Docker for Mac uses new lightweight virtualization called [Hyperkit]. It's based on xhyve/bhyve which is running on top of native Mac OS X Hypervisor.framework.

Unfortunately, old problems are still here.

### Slow mount volumes

It has been a problem for quite a long time. If you want to use Docker for development, you need to be able to edit code on your host machine and see the changes immediately inside the container so that you can refresh browser or re-run the test. The solution for this problem is a host directory mount. You simply mount your local code directory inside the container and enjoy the life. Not so fast.

[osxfs] is the file system in Docker which is used for mounting host directories. It is really slow. There's a [wonderful forum thread](https://forums.docker.com/t/file-access-in-mounted-volumes-extremely-slow-cpu-bound/8076) dedicated to this particular problem.  But, to summarize, consider the following example:

    $ gem install rails
    $ rails new docker-volumes
    $ cd docker-volumes
    $ bundle install --deployment

Then drop the following Dockerfile inside the `docker-volumes` directory:

    FROM ruby:2.3.1

    RUN mkdir /app
    WORKDIR /app

    ADD . /app
    RUN bundle install --deployment
    RUN apt-get update && apt-get -y install nodejs

Let's try to run rails runner without mounting host directory:

    $ docker run --rm docker-volumes /bin/bash -c "time rails runner ''"
    real       0m1.366s
    user       0m0.500s
    sys        0m0.100s

Not so bad, huh? Now run it with host directory mounted:

    $ docker run -v `pwd`:/app --rm docker-volumes /bin/bash -c "time rails runner ''"
    real       0m11.348s
    user       0m0.480s
    sys        0m0.350s

Bummer, 10 times slower. Fortunately, there's a few workarounds available:

- [docker-sync] - It will create a special volume container with rsync daemon inside it which can be used to synchronize host directory
- You can keep all your bundle dependencies inside the container file system so that when you run rake / rails commands, they are loaded faster. Code directory on host machine will be mounted as an external volume.

Option #1 is faster because you don't have to mount host directory at all. rsync is used for synchronizing code between host and container and it's incredibly fast. Disadvantage of this approach is that you have to install a separate tool (docker-sync) and run command which will be monitoring local system changes. Whenever it detects a new file change, it will run rsync which will synchronize it with the container.

Option #2 is slower but you can use this option without installing additional tools. The trick here is to install all project dependencies into directory which is stored inside the container (i.e. running `bundle install` without `--deployment` option). Whenever you will be running rake or rails command, it will be loading all dependencies from container directory which is faster than loading them from host machine volume. You still have to mount code directory and there's still overhead of loading files from code directory, but it's usually taking much less time than loading application code plus all the dependencies.

## Injecting secrets during build process

Imagine a typical case - you have a Ruby application and your Gemfile contains dependencies which are pointing to private GitHub repositories. It means that it relies on a fact that user or CI system which is installing bundle should have an access to all of them. GitHub is using public-private key authentication system and it means that there should be a private key inside the container so that Docker can clone private repositories.

### Serving private key over HTTP

There's a well-known hack which allows connecting to host machine over HTTP during container build time. First, you need to serve your private key over HTTP on a host machine. Ruby comes with a bundled HTTP server, you can serve your private key like this:

    $ ruby -run -ehttpd ~/.ssh/id_rsa -p80

If you'll try to run the following curl command, you can see that your private key is now accessible through port 80 inside the host network:

    $ curl http://localhost

It's a good idea to protect this port with a firewall so that it's not accessible through public network.

Then you need to get IP address of host machine and download the key. Then add the following to your Dockerfile:

    RUN curl $(ip route|awk '/default/{print $3}') > $HOME/.ssh/id_rsa && \
         chmod 0600 $HOME/.ssh/id_rsa && \
         ssh-keyscan -t rsa github.com > $HOME/.ssh/known_hosts && \
         bundle install && \
         rm -f $HOME/.ssh/id_rsa

It will find out the ip address of your host machine by running `ip route` command. You private key which is served over HTTP will be saved to `~/.ssh/id_rsa` file. It will also run `ssh-keyscan` to add github.com SSH fingerprint to `~/.ssh/known_hosts` file so that `bundle install` command does not complain about github.com which is not yet known to the system. After installing bundle, it will delete private key. It's important to only have one `RUN` statement inside the Dockerfile which will do everything so that private key won't be left behind in build cache.

### Adding private key to the container and squashing the final image

Another option is to add the private key to the container and delete it after bundle was installed. Unfortunately, it still leaves a trace of it in Docker build history. But there's a nice tool called [docker-squash] which will squash all of the container layers into one and essentially will delete private key from the history.

## docker compose limitations

The new version of docker-compose comes with `extends` capabilities. You can extend your services with common properties. Example use case is when you have Ruby on Rails app and sidekiq which are using the same code base:

docker-compose-common.yml:

{% highlight yaml %}
app:
     build: .
     environment:
          RAILS_ENV: production
     links:
          - mysql
          - redis
{% endhighlight %}

docker-compose.yml:

{% highlight yaml %}
rails:
     extends:
          file: docker-compose-common.yml
          service: app
     command: bundle exec rails server

sidekiq:
     extends:
          file: docker-compose-common.yml
          service: app
     command: bundle exec sidekiq
{% endhighlight %}

Unfortunately, you can only extend with one service at a time which means you can't compose multiple chunks of configuration. I found that using YAML anchors is more productive and gives more flexibility. Example docker-compose.yml:

{% highlight yaml %}
rails: &app
     build: .
     environment:
          RAILS_ENV: production
     links:
          - mysql
          - redis
     command: bundle exec rails server

sidekiq:
     <<: *app
     command: bundle exec sidekiq
{% endhighlight %}

[Hyperkit]: https://github.com/docker/hyperkit
[docker-squash]: https://github.com/jwilder/docker-squash
[rocker]: https://github.com/grammarly/rocker
[osxfs]: https://docs.docker.com/docker-for-mac/osxfs/
[docker-sync]: http://docker-sync.io/
