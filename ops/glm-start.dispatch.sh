# Paste into your existing start script (the unit's ExecStart), after it has waited for the worker and before it
# launches the old stack. With ~/.glm-engine saying ENGINE=tf it hands over to TensorFold; otherwise it falls through.
ENGINE=$(sed -n 's/^ENGINE=//p' "$HOME/.glm-engine" 2>/dev/null | head -1)
if [ "${ENGINE:-vllm}" = tf ]; then exec /path/to/glm53-tensorfold-spark-recipe/ops/glm-tf-start.sh; fi
docker rm -f glm-proxy >/dev/null 2>&1   # the TensorFold key proxy holds :8000; free it for the old stack

# And in the stop script (ExecStop), first line, unconditionally (it is a no-op when TensorFold is not up):
#   /path/to/glm53-tensorfold-spark-recipe/ops/glm-tf-stop.sh
