import envoy
import gleeunit

pub fn main() -> Nil {
  // The store's tests commit codes: keep them out of ./data/codes.tsv.
  envoy.set("CODES_FILE", "./build/test-codes.tsv")
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}
