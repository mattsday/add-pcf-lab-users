# Add PCF Users
This script makes it easier to add users to PCF (PAS and PKS).

## What it does
It will create users from a provided list and:

1. Create PAS accounts
	* Create a shared org
	* Create a user-specific org
	* Add owner rights to both
	* Give healthwatch and network user rights
2. Create PKS accounts
3. Create read-only ops manager accounts

## How to use it
Copy `config-example.sh` to `config.sh` and edit the values (ops man details and user email addresses).

