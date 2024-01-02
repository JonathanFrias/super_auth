f# SuperAuth

Super auth is turn-key authorization gem that makes unauthorized access unrepresentable. **Stop writing tests for authorization with confidence**

The intent is to use with ruby applications, as well as centralize authorization for multiple applications. If you look at the [OWASP top vulnerabilty](https://owasp.org/Top10/A01_2021-Broken_Access_Control/), broken
access control is the NUMBER 1 most common security risk in modern applications today. super_auth provides a authentication strategy that allows you to completely de-risk your application, solving this issue once confidently.


## Installation

    gem "super_auth"


## Docs

How `super_auth` stacks up against other authentication strategies:
[Do you really understand Authentication](https://dev.to/jonathanfrias/do-you-really-understand-authorization-1o5d)

## Usage

SuperAuth is a rules engine engine that works on 5 different authorization concepts:

- Users
- Groups
- Roles
- Permissions
- Resources

The basis for how this works is that the rules engine is trying to match a user with a resource to determine access.
The engine determines if it can find an authorization route betewen a user and a resource. It does so by looking at users, groups, roles, permissions.

                         +-------+       +------+
                         | Group |<----->| Role |
                         +-------+\    / +------+
                             ^     \  /     ^
                             |      \/      |
                             |      /\      |
                             |     /  \     |
                             V    /    \    V
    +---------------+    +------+/      \+------------+    +----------+      +-------------------+
    | YourApp::User |<-->| User |<------>| Permission |<-->| Resource | <--> | YourApp::Resource |
    +---------------+    +------+        +------------+    +----------+      +-------------------+
                             ^                                  ^
                             |                                  |
                             +----------------------------------+


The lines between the boxes are called [edges](https://en.wikipedia.org/wiki/Glossary_of_graph_theory#edge).
Note that `Group` and `Role` trees.

In general the super_auth has 5 different pathing strategies to search for access.

    1. users <-> group[s] <-> role[s] <-> permission <-> resource
    2. users <->              role[s] <-> permission <-> resource
    3. users <-> group[s] <->             permission <-> resource
    4. users <->                          permission <-> resource
    5. users <->                                         resource

Edges can be drawn between any 2 objects, allowing super_auth can seamlessly scale in complexity with you.
When `Group` and `Role` are used, the rules will apply to all descedants. If there are any edges
between the specified user and the resource, then access is granted.


You can see usage examples `spec/example_spec.rb`.

We're going to need some users:

    Users:
      - Peter
      - Michael
      - Bethany
      - Eloise
      - Anna
      - Dillon
      - Guest (Unknown User)

Let's see an example company structure:

    Groups:
      - Company
        - Engineering_dept
          - Backend
          - Frontend
        - Sales Department
        - Marketing Department
      - Customers
        - CustomerA
        - CustomerB
      - Vendors
        - VendorA
        - VendorB

We're going to define a roles:

    Roles:
      - Employee
        - Engineering
          - Señor Software Developer
          - Señor Designer
          - Software Developer
          - Production Support
        - Sales and Marketing
          - Marketing Manager
          - Marketing Associate
      - CustomerRole

We're going to define some permissions:

    Permissions:
      - create
      - read
      - update
      - delete
      - invoice
      - login
      - reboot
      - deploy
      - sign_contract
      - subscribe
      - unsubscribe
      - publish_design

Finally, we need some resources:

    Resources:
      - app1
      - app2
      - staging
      - db1
      - db2
      - core_design_template
      - customer_profile
      - marketing_website
      - customer_post1
      - customer_post2
      - customer_post3

So we have sufficient prerequisite data to do some interesting authorizations. Let's draw some edges:

    Peter <-> Frontend # Peter is on the Frontend team. (via Company->Engineering_dept->Frontend)
    Engineering_dept <-> Engineering # Group "Engineering_dept" has the Role "Engineering"
    Engineering <-> create # Engineering role can do basic CRUD operations
    Engineering <-> read   # Peter can CRUD too
    Engineering <-> update
    Engineering <-> delete
    core_design_template <-> create # Now, those CRUD permissions apply to core_design_template resource
    core_design_template <-> read
    core_design_template <-> update
    core_design_template <-> delete

With this, the following paths are created from Peter to the core_design_template:

    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> create <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> read   <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> update <-> core_design_template
    Peter <-> Frontend <-> Engineering_dept <-> Engineering <-> delete <-> core_design_template

    Which completes the circuit using the path
    user <-> group <-> group <-> role <-> permission <-> resource


When you create/delete an edge new authorizations are generated and stored in the `super_auth` database table.
Since the path is stored with the record, it trivial to audit access permissions using basic SQL.

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/JonathanFrias/super_auth.

## License

The gem is available as open source under the terms of the [GPL](https://www.gnu.org/licenses/quick-guide-gplv3.html).
