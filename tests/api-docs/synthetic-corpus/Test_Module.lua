local TestSpell =
{
    Name = "C_Test",
    Type = "System",

    Functions =
    {
        {
            Name = "GetSecretValue",
            Type = "Function",
            SecretWhenCooldownsRestricted = true,
            Returns = { { Name = "value", Type = "number", Nilable = false } },
        },
        {
            Name = "GetCleanValue",
            Type = "Function",
            Returns = { { Name = "value", Type = "number", Nilable = false } },
        },
        {
            Name = "RestrictedReturn",
            Type = "Function",
            SecretArguments = "Restricted",
            Returns = { { Name = "value", Type = "number", IsSecret = true } },
        },
    },
}

APIDocumentation:AddDocumentationTable(TestSpell)
