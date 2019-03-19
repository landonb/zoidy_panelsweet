zoidy_panelsweet
================

An Ansible role customize ``mate-panel`` launchers and layout.

Requirements
------------

A fresh install of MATE, and some custom variable settings.

Example Playbook
----------------

It's simple to run the role from a playbook.

Add the role to the playbook::

  - hosts: servers
    roles:
       - role: zoidy_panelsweet

Then run the play::

  ansible-playbook path/to/site.yml -K

If you want to restrict what's installed to a specific group, use tags, e.g.,::

  ansible-playbook path/to/site.yml -K --tags panels-awesome

License
-------

`GPLv3 <LICENSE>`__

