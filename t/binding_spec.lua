local utils = require "utils"

describe("binding", function()
  local binding, saml

  local redirect_signature = ""

  setup(function()
    saml = {
      find_transform_by_href  = stub().returns("alg"),
      doc_read_memory         = stub(),
      doc_validate            = stub(),
      create_keys_manager     = stub(),
      sign_binary             = stub(),
      verify_binary           = stub(),
      sign_xml                = stub(),
      verify_doc              = stub(),
    }
    package.loaded["saml"] = saml

    binding = require "resty.saml.binding"

    stub(ngx.req, "get_method")
    stub(ngx.req, "get_post_args")
    stub(ngx.req, "get_uri_args")
    stub(ngx.req, "read_body")
  end)

  teardown(function()
    package.loaded["saml"] = nil
    ngx.req.get_method:revert()
    ngx.req.get_post_args:revert()
    ngx.req.get_uri_args:revert()
    ngx.req.read_body:revert()
  end)

  before_each(function()
    for _, m in pairs(saml) do
      m:clear()
    end
    ngx.req.get_method:clear()
    ngx.req.get_post_args:clear()
    ngx.req.get_uri_args:clear()
    ngx.req.read_body:clear()
  end)


  describe(".create_redirect()", function()

    it("constructs the query string for the signature", function()
      saml.sign_binary.returns(nil, "signature failed")
      binding.create_redirect("key", { SigAlg = "alg", SAMLRequest = "xml", RelayState = "relay_state" })
      assert.spy(saml.sign_binary).was.called_with("key", "alg", match._)
      local args = saml.sign_binary.calls[1].vals
      assert.are.equal("SAMLRequest=q8jNAQA%3D&RelayState=relay_state&SigAlg=alg", args[3])
    end)

    it("errors for signature failure", function()
      saml.sign_binary.returns(nil, "signature failed")
      local query_string, err = binding.create_redirect("key", { SigAlg = "alg", SAMLRequest = "xml", RelayState = "relay_state" })
      assert.are.equal("signature failed", err)
      assert.is_nil(query_string)
    end)

    it("creates a full query string", function()
      saml.sign_binary.returns("signature", nil)
      local query_string, err = binding.create_redirect("key", { SigAlg = "alg", SAMLRequest = "xml", RelayState = "relay_state" })
      assert.is_nil(err)
      assert.are.equal("SAMLRequest=q8jNAQA%3D&RelayState=relay_state&SigAlg=alg&Signature=c2lnbmF0dXJl", query_string)
    end)

  end)


  describe(".parse_redirect()", function()
    local cb = function(doc) return "-----BEGIN CERTIFICATE-----" end
    local cb_error = function(doc) return nil end
    local parsed = "parsed document"
    local default_args = {
      SigAlg = "alg",
      SAMLRequest = "q8jNAQA=",
      RelayState = "relay_state",
      Signature = "c2lnbmF0dXJl",
    }

    before_each(function()
      ngx.req.get_method.returns("GET")
      ngx.req.get_uri_args.returns(default_args)
      saml.verify_binary.returns(true, nil)
      saml.doc_read_memory.returns(parsed)
      saml.doc_validate.returns(true)
    end)

    it("errors for non-GET method", function()
      ngx.req.get_method.returns("POST")
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb_error)
      assert.are.equal("method not allowed", err)
      assert.is_nil(doc)
      assert.is_nil(args)
    end)

    it("errors for missing content", function()
      ngx.req.get_uri_args.returns({})
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb_error)
      assert.are.equal("no SAMLRequest", err)
      assert.is_nil(doc)
      assert.are.same({}, args)
    end)

    it("errors for invalid xml", function()
      saml.doc_read_memory.returns(nil)
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb_error)
      assert.are.equal("SAMLRequest is not valid xml", err)
      assert.is_nil(doc)
      assert.are.same(default_args, args)
    end)

    it("errors for invalid document", function()
      saml.doc_validate.returns(false)
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb_error)
      assert.are.equal("document does not validate against schema", err)
      assert.are.equal(parsed, doc)
      assert.are.same(default_args, args)
    end)

    it("errors when no cert is found", function()
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb_error)
      assert.are.equal("no cert", err)
      assert.are.equal(parsed, doc)
      assert.are.same(default_args, args)
    end)

    it("passes args to verify function", function()
      binding.parse_redirect("SAMLRequest", cb)
      assert.spy(saml.verify_binary).was.called(1)
      local args = saml.verify_binary.calls[1].vals
      assert.are.equal(args[1], "-----BEGIN CERTIFICATE-----")
      assert.are.equal(args[2], "alg")
      assert.are.equal(args[3], "SAMLRequest=q8jNAQA%3D&RelayState=relay_state&SigAlg=alg")
      assert.are.equal(args[4], "signature")
    end)

    it("errors for verify failure", function()
      saml.verify_binary.returns(false, "verify failed")
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb)
      assert.are.equal(err, "verify failed")
      assert.are.equal(parsed, doc)
    end)

    it("errors for invalid signature", function()
      saml.verify_binary.returns(false, nil)
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb)
      assert.are.equal(err, "invalid signature")
      assert.are.equal(parsed, doc)
    end)

    it("returns the parsed document", function()
      saml.verify_binary.returns(true, nil)
      local doc, args, err = binding.parse_redirect("SAMLRequest", cb)
      assert.is_nil(err)
      assert.are.equal(parsed, doc)
    end)

  end)

  describe(".create_post()", function()

    before_each(function()
      saml.sign_xml.returns("signed request", nil)
    end)

    it("signs a request", function()
      binding.create_post("key", "alg", "dest", { SAMLRequest = "request" })
      assert.spy(saml.sign_xml).was.called_with("key", "alg", "request", match.is_table())
    end)

    it("signs a response", function()
      binding.create_post("key", "alg", "dest", { SAMLResponse = "response" })
      assert.spy(saml.sign_xml).was.called_with("key", "alg", "response", match.is_table())
    end)

    it("aborts without a request or response", function()
      assert.has_error(function()
        binding.create_post("key", "alg", "dest", {})
      end, "no saml request or response")
    end)

    it("errors for signature failure", function()
      saml.sign_xml.returns(nil, "signature failed")
      local html, err = binding.create_post("key", "alg", "dest", { SAMLRequest = "request" })
      assert.are.equal("signature failed", err)
      assert.is_nil(html)
    end)

    it("passes the destination", function()
      local html, err = binding.create_post("key", "alg", "dest", { SAMLRequest = "request" })
      assert.is_nil(err)
      local action = html:match('action="(%w+)"')
      assert.are.equal("dest", action)
    end)

    it("passes a copy of the params", function()
      local params = { SAMLRequest = "request", RelayState = "relay" }
      local html, err = binding.create_post("key", "alg", "dest", params)
      assert.is_nil(err)
      assert.are.same({
        SAMLRequest = "request",
        RelayState = "relay",
      }, params)
    end)

    it("returns the form template", function()
      local html, err = binding.create_post("key", "alg", "dest", { SAMLRequest = "request" })
      assert.is_nil(err)
      assert.is_not_nil(html:find("<html>"))

      local name, value = html:match('name="([^"]+)" value="([^"]+)"')
      assert.are.equal("SAMLRequest", name)
      assert.are.equal("c2lnbmVkIHJlcXVlc3Q=", value)
    end)

  end)


  describe(".parse_post()", function()
    local input_doc = "<Response>"
    local parsed = "parsed document"
    local mngr = { cert = "" }
    local cb = function(doc) return mngr end
    local cb_error = function(doc) return nil end
    local default_args = { SAMLRequest = "PFJlc3BvbnNlPg==" }

    before_each(function()
      ngx.req.get_method.returns("POST")
      ngx.req.get_post_args.returns(default_args, nil)
      saml.create_keys_manager.returns(mngr)
      saml.verify_doc.returns(true, nil)
      saml.doc_read_memory.returns(parsed)
      saml.doc_validate.returns(true)
    end)

    it("errors for non-POST method", function()
      ngx.req.get_method.returns("GET")
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.are.equal("method not allowed", err)
      assert.is_nil(doc)
      assert.is_nil(args)
    end)

    it("errors for argument retrieval", function()
      ngx.req.get_post_args.returns(nil, "bad request body")
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.are.equal("bad request body", err)
      assert.is_nil(doc)
      assert.is_nil(args)
    end)

    it("errors for missing content", function()
      ngx.req.get_post_args.returns({}, nil)
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.are.equal("no SAMLRequest", err)
      assert.is_nil(doc)
      assert.are.same({}, args)
    end)

    it("errors for invalid xml", function()
      saml.doc_read_memory.returns(nil)
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.spy(saml.doc_read_memory).was.called_with("<Response>")
      assert.are.equal("SAMLRequest is not valid xml", err)
      assert.is_nil(doc)
      assert.are.same(default_args, args)
    end)

    it("errors for invalid document", function()
      saml.doc_validate.returns(false)
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.are.equal("document does not validate against schema", err)
      assert.are.equal(parsed, doc)
    end)

    it("errors when no cert is found", function()
      local doc, args, err = binding.parse_post("SAMLRequest", cb_error)
      assert.are.equal("no key manager", err)
      assert.are.equal(parsed, doc)
    end)

    it("passes args to verify function", function()
      binding.parse_post("SAMLRequest", cb)
      assert.spy(saml.verify_doc).was.called(1)
      local args = saml.verify_doc.calls[1].vals
      assert.are.same(mngr, args[1])
      assert.are.equal(parsed, args[2])
    end)

    it("errors for verify failure", function()
      saml.verify_doc.returns(false, "verify failed")
      local doc, args, err = binding.parse_post("SAMLRequest", cb)
      assert.are.equal(err, "verify failed")
      assert.are.equal(parsed, doc)
    end)

    it("errors for invalid signature", function()
      saml.verify_doc.returns(false, nil)
      local doc, args, err = binding.parse_post("SAMLRequest", cb)
      assert.are.equal(err, "invalid signature")
      assert.are.equal(parsed, doc)
    end)

    it("returns the parsed document", function()
      saml.verify_doc.returns(true, nil)
      local doc, args, err = binding.parse_post("SAMLRequest", cb)
      assert.is_nil(err)
      assert.are.equal(parsed, doc)
    end)
  end)

end)
