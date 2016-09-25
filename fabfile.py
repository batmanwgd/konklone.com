import time
from fabric.api import run, execute, env

environment = "production"

env.use_ssh_config = True
env.hosts = ["konklone.com"]

branch = "master"
repo = "git@github.com:konklone/konklone.com.git"

keep = 3

socket = "konklone"
home = "/home/eric/konklone.com" 
shared_path = "%s/shared" % home
versions_path = "%s/versions" % home
version_path = "%s/%s" % (versions_path, time.strftime("%Y%m%d%H%M%S"))
current_path = "%s/current" % home


# can be run only as part of deploy

def cleanup():
  versions = run("ls -x %s" % versions_path).split()
  destroy = versions[:-keep]

  for version in destroy:
    command = "rm -rf %s/%s" % (versions_path, version)
    run(command)

def checkout():
  run('git clone -q -b %s %s %s' % (branch, repo, version_path))

def links():
  run("ln -s %s/config.yml %s/config/config.yml" % (shared_path, version_path))
  run("ln -s %s/config.ru %s/config.ru" % (shared_path, version_path))
  run("ln -s %s/cache %s/cache" % (shared_path, version_path))

def dependencies():
  run("cd %s && bundle install --local" % version_path)

def create_indexes():
  run("cd %s && bundle exec rake create_indexes" % version_path)

def make_current():
  run('rm -f %s && ln -s %s %s' % (current_path, version_path, current_path))

def set_crontab():
  run("cd %s && bundle exec rake set_crontab environment=%s current_path=%s" % (current_path, environment, current_path))


## can be run on their own

def start():
  run("cd %s && bundle exec unicorn -D -l %s/%s.sock -c unicorn.rb" % (current_path, shared_path, socket))

def stop():
  run("kill `cat %s/unicorn.pid`" % shared_path)

def restart():
  stop()
  start()


def deploy():
  execute(checkout)
  execute(links)
  execute(dependencies)
  execute(create_indexes)
  execute(make_current)
  execute(set_crontab)
  execute(restart)
  execute(cleanup)


# only difference is it uses start instead of restart
def deploy_cold():
  execute(checkout)
  execute(links)
  execute(dependencies)
  execute(create_indexes)
  execute(make_current)
  execute(set_crontab)
  execute(start)
