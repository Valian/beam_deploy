# BeamDeploy example

A tiny Phoenix app that rebuilds and swaps itself with BeamDeploy.

## Run the demo

```sh
cd example
./start.sh
```

Open http://localhost:4000 and click one of the buttons.

You can override the port or initial label:

```sh
PORT=4010 DEMO_BUTTON_LABEL="Ship the green build" ./start.sh
```

Each button starts a production release build with a different compile-time label, hands the new release tarball to `BeamDeploy.upgrade/1`, and the page comes back with the new label after the blue-green peer swap.
