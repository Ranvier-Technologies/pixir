defmodule PixirMonitor.Bootstrap do
  @moduledoc """
  Owns the immutable inline bootstrap bytes, exact CSP hash, and the narrowly
  allowlisted `pixir-bootstrap` Trusted Types script-URL policy.

  The script removes the fragment before creating subresources and exchanges the
  one-use capability without placing it in a request URL.
  """

  @source ~S|(function(){"use strict";const launch=new URLSearchParams(location.hash.slice(1)).get("launch");const capabilityAbsent=launch===null;history.replaceState(null,"","/");document.title="Pixir Monitor";window.__pixirBootstrap=fetch("/bootstrap",{method:"POST",headers:{"content-type":"application/json"},credentials:"same-origin",body:JSON.stringify({launch:launch})}).then(function(response){if(!response.ok)throw new Error(response.status===401?(capabilityAbsent?"capability_absent":"capability_rejected"):"bootstrap_failed");const appScript="/assets/app.js";let trustedAppScript=appScript;if(window.trustedTypes){const policy=window.trustedTypes.createPolicy("pixir-bootstrap",{createScriptURL:function(value){if(value===appScript)return appScript;throw new TypeError("blocked script URL");}});trustedAppScript=policy.createScriptURL(appScript);}const css=document.createElement("link");css.rel="stylesheet";css.href="/assets/app.css";document.head.append(css);const script=document.createElement("script");script.src=trustedAppScript;script.defer=true;script.onerror=function(){var status=document.getElementById("status");if(status)status.textContent="Monitor interface failed to load. Reload the page, or run pixir-monitor serve again for a fresh session.";};document.head.append(script);});window.__pixirBootstrap.catch(function(error){var status=document.getElementById("status");if(!status)return;var kind=error&&error.message;if(kind==="capability_absent"){status.textContent="Open the Monitor through the one-use link printed by pixir-monitor serve. This page was opened without one.";}else if(kind==="capability_rejected"){status.textContent="Launch link invalid, expired, or already used. Launch tokens are one-use and expire in 30 seconds. Run pixir-monitor serve again to mint a fresh one.";}else{status.textContent="Monitor failed to start before loading. Reload the page, or run pixir-monitor serve again for a fresh session.";}});}());|

  def source, do: {:ok, @source}
  def csp_hash, do: {:ok, :crypto.hash(:sha256, @source) |> Base.encode64()}

  def shell do
    case PixirMonitor.WorkspaceSet.mode() do
      {:ok, :single} -> single_shell()
      {:ok, :workspace_set} -> workspace_set_shell()
    end
  end

  defp single_shell do
    {:ok,
     "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Pixir Monitor</title><script>" <>
       @source <>
       "</script></head><body><main aria-label=\"Pixir Monitor\"><h1>Pixir Monitor</h1><p id=\"status\" role=\"status\">Starting read-only monitor…</p><div id=\"app\"></div></main></body></html>"}
  end

  defp workspace_set_shell do
    with {:ok, sources} <- PixirMonitor.WorkspaceSet.configured() do
      config = Jason.encode!(%{mode: "workspace_set", workspaces: Enum.map(sources, & &1.key)})
      attribute = html_attribute_escape(config)

      {:ok,
       "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Pixir Monitor</title><script>" <>
         @source <>
         "</script></head><body><main aria-label=\"Pixir Monitor\" data-workspace-set=\"#{attribute}\"><h1>Pixir Monitor</h1><p id=\"status\" role=\"status\">Starting read-only monitor…</p><div id=\"app\"></div></main></body></html>"}
    end
  end

  defp html_attribute_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("'", "&#39;")
  end
end
