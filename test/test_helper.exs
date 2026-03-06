ExUnit.start(exclude: [:integration])

if !Node.alive?() do
  System.cmd("epmd", ["-daemon"])
  {:ok, _} = :net_kernel.start([:beam_deploy_tests, :shortnames])
  Node.set_cookie(:beam_deploy_cookie)
end
