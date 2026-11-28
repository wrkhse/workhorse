              if any(.[]; (.id | type) != "number" or (.user.id? | type) != "number"
                     or ((.body? // "") | type) != "string") then
                error("unexpected comment shape")
              else . end
              | [ .[] | select(.user.id == $author)
                  | select(.body | startswith($marker)) ]
              | if length == 0 then error("no review marker comment from the bot")
                else . end
              | sort_by(.id) | last | .body
              | . as $comment
              | ($comment | split("\n") | .[3] // "") as $meta_line
              | (if ($meta_line | startswith("<!-- opencode-review-meta ") and endswith(" -->"))
                   then (try ($meta_line
                        | ltrimstr("<!-- opencode-review-meta ")
                        | rtrimstr(" -->") | fromjson) catch null)
                   else null end) as $meta
              | if ($meta | type) != "object" then
                  error("posted review has no matching head binding for \($head)")
                elif $meta.head != $head then
                  error("posted review has no matching head binding for \($head)")
                else $comment end
              | split("\n")
              | map(select(test("^\\*\\*Verdict:[^*]*\\*\\*$")))
              | if length != 1 then error("posted review has no single verdict line")
                else .[0] end
              | if . == "**Verdict: MERGE AS IS**" or . == "**Verdict: ADVISORY**" then
                  "Posted verdict \(.) allows the merge."
                else error("posted verdict \(.) blocks the merge") end
