---
layout: post
comments: true
title: Deploying Ruby on Rails applications with ansible
---

[capistrano] was the best Ruby on Rails deployment tool for a years, but if you want to apply DevOps practices in your project then you might want to try out [ansible]. It allows you to significantly simplify your operations by creating easy YAML-based playbooks. It's good for configuration automation, deployments and orchestration. And most important - [ansible] is very easy to learn.

I've used [capistrano] previously for fairly complex multi-server deployments. I've also used [chef] for configuration automation. But I literally fell in love with [ansible] after trying it for the first time because it's very easy to start using it and it does not requires server to run agent - it directly connects over SSH to the server and applies configuration. [ansible] fits into keep it simple principle - having one tool to rule them all makes more sense than using separate tools for configuration and for deployments.

If you want to start with [ansible] quickly then you can try out [railsbox.io] which will generate [ansible] playbooks for common Ruby on Rails deployments. Keep reading if you'd like to get familiar with [ansible] and to create deployment playbook manually.

## Deploying with capistrano

[capistrano] deploys to the new dir each time and keeps the latest release as a symlink so that frontend and backend servers can both be configured to point to this symlink to serve latest application code. Typical Ruby on Rails application which is deployed with [capistrano] has the following file structure on server:

    application/
      shared/
        config/
        log/
        pids/
        system/
      releases/
        20150312000000/
        20150313000000/
        20150314000000/
      current -> releases/20150314000000

When you run `cap deploy`, [capistrano] will create new release directory under `application/releases` and copy the latest git snapshot into it. It will then run the following tasks:

* `rake assets:precompile`
* `rake db:migrate`
* symlink configuration files from `application/shared/config` directory to the current release
* restart server

[capistrano] is great, but if you're already using [ansible] for configuration management or planning to start using it then it totally makes sense to get rid of [capistrano] as unneeded dependency and reproduce the same procedure with [ansible] playbook.

## Deploying with ansible

[ansible] is using YAML for configuration and for actual commands. It has less flexibility compared to capistrano which uses Ruby DSL, but at the same time helps you to keep your playbooks simple. [ansible] also extremely good with orchestration and rolling deployments.

### Configuration

We need to create configuration file for our deployments first - it will reside in `group_vars/all/config.yml` file. I will use configuration for [railsbox.io] as an example.

{% highlight yaml %}
{% raw %}
---
app_name: railsbox
rails_env: production

git_url: git@github.com:andreychernih/railsbox.git
git_version: master

app_path: '/{{ app_name }}'
shared_path: '{{ app_path }}/shared'
releases_path: '{{ app_path }}/releases'
current_release_path: '{{ app_path }}/current'
app_public_path: "{{ current_release_path }}/public"
app_config_path: "{{ current_release_path }}/config"
app_temp_path: "{{ current_release_path }}/tmp"
app_logs_path: "{{ current_release_path }}/log"

keep_releases: 5
{% endraw %}
{% endhighlight %}

All YAML files should start with `---`. [ansible] uses [Jinja2] as templating engine. It means that everything between `{% raw %}{{{% endraw %}` and `}}` will be interpolated.

Let's also create inventory file which [ansible] will use to associate real hosts with groups. Create file named `production` and put the following into it:

    [production]
    railsbox.io

It tells ansible that `railsbox.io` host belongs to `production` group. We will also use SSH agent forwarding so that it will be possible to deploy applications which reside in private repositories without need for uploading deployment keys. Create `ansible.cfg` with the following contents:

    [ssh_connection]
    ssh_args = -o ForwardAgent=yes -o ControlMaster=auto -o ControlPersist=60s

Since [ansible] is using SSH for running commands, we need to use [OpenSSH ControlMaster] feature to keep things fast. [ansible] will create SSH connection at the beginning and then will reuse it for all subsequent commands in play.

### Playbook

Now when we have configuration we can create the actual playbook for doing capistrano-style deployments. Create `deploy.yml` file:

{% highlight yaml %}
{% raw %}
---
- hosts: all
  tasks:
    - set_fact: this_release_ts={{ lookup('pipe', 'date +%Y%m%d%H%M%S') }}
    - set_fact: this_release_path={{ releases_path }}/{{ this_release_ts }}

    - debug: msg='New release path {{ this_release_path }}'

    - name: Create new release dir
      file: path={{ this_release_path }} state=directory

    - name: Update code
      git: repo={{ git_url }} dest={{ this_release_path }} version={{ git_version }} accept_hostkey=yes
      register: git

    - debug: msg='Updated repo from {{ git.before }} to {{ git.after }}'

    - name: Symlink shared files
      file: src={{ shared_path }}/{{ item }} dest={{ this_release_path }}/{{ item }} state=link force=yes
      with_items:
        - config/database.yml
        - config/secrets.yml
        - config/unicorn.rb
        - log
        - tmp
        - vendor/bundle

    - name: Install bundle
      command: 'bundle install --deployment --without="development test"'
      args:
        chdir: '{{ this_release_path }}'

    - name: Precompile assets
      command: rake assets:precompile chdir={{ this_release_path }}
      environment:
        RAILS_ENV: '{{ rails_env }}'

    - name: Migrate database
      command: rake db:migrate chdir={{ this_release_path }}
      environment:
        RAILS_ENV: '{{ rails_env }}'

    - name: Symlink new release
      file: src={{ this_release_path }} dest={{ current_release_path }} state=link force=yes

    - name: Restart unicorn
      command: sudo restart {{ app_name }}

    - name: Cleanup
      shell: "ls -1t {{ releases_path }}|tail -n +{{ keep_releases + 1 }}|xargs rm -rf"
      args:
        chdir: '{{ releases_path }}'
{% endraw %}
{% endhighlight %}

Above playbook should be self-explanotary, but I wanted to outline a couple of moments.

Make sure that you're pointing `git_url` to SSH-type URL so that it uses SSH keys for connecting to git server. If you're using private repository and you've enabled SSH agent forwarding, it will just work. You don't have to upload your private key to the server.

You should run and deploy your application using non-privileged user. It will help to enforce the security, but can complicate the deployment sometimes. [railsbox.io] creates [upstart] script for [unicorn] server, but it has one problem - only root user can start and stop [upstart] services. That's why we have to use `sudo`. We're limiting it to be able to run only 3 commands by creating `/etc/sudoers.d/railsbox` with the following contents:

    railsbox ALL=NOPASSWD: /sbin/start railsbox, /sbin/stop railsbox, /sbin/restart railsbox

### Deploy

Once everything is set up, you can run the following command to deploy:

    ansible-playbook -u railsbox -i production deploy.yml

[capistrano]: http://capistranorb.com/
[ansible]: http://www.ansible.com/
[chef]: https://www.chef.io/
[railsbox.io]: https://railsbox.io/
[OpenSSH ControlMaster]: http://en.wikibooks.org/wiki/OpenSSH/Cookbook/Multiplexing
[upstart]: http://upstart.ubuntu.com/
[unicorn]: http://unicorn.bogomips.org/
[Jinja2]: http://jinja.pocoo.org/docs/dev/
