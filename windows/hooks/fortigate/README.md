# Connexa ACME FortiGate Hook Pack

This hook pack deploys a downloaded PFX certificate from the Connexa ACME Windows fetch agent to one or more FortiGates.

## Requirements

The ACME service must be created with RSA for FortiGate compatibility:

```json
{
  "certificate_type": "wildcard",
  "deployment_type": "agent",
  "key_type": "rsa"
}
```

The Windows agent config must use PFX:

```json
{
  "Format": "pfx",
  "PfxPassword": "same-password-as-fortigate.xml",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\fortigate"
}
```

## Install

Copy these files to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\fortigate\
```

Then copy:

```text
fortigate.example.xml
```

to:

```text
fortigate.xml
```

and configure FortiGate host(s), API token(s), VDOM and certificate name.

## Hook order

`20-UploadFortigate.ps1` is executed by the agent when a new certificate version is downloaded.

## Exit codes

- `0` success
- `1` warning/partial failure from uploader
- `2` retry next agent run
- `3+` fatal configuration error
