// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

namespace Microsoft.Quantum.Canon
{
    open Microsoft.Quantum.Primitive;
    open Microsoft.Quantum.Extensions.Math;
    open Microsoft.Quantum.Extensions.Convert;

    /// # Summary
	/// Uses the Quantum ROM technique to represent a given density matrix.
	/// 
    /// Given a list of $N$ coefficients $\alpha_j$, this returns a unitary $U$ that uses the Quantum-ROM
    /// technique to prepare
    /// an approximation  $\tilde\rho\sum^{N-1}_{j=0}p_j\ket{j}\bra{j}$ of the purification of the density matrix 
    /// $\rho=\sum^{N-1}_{j=0}\frac{|alpha_j|}{\sum_k |\alpha_k|}\ket{j}\bra{j}$. In this approximation, the 
    /// error $\epsilon$ is such that $|p_j-\frac{|alpha_j|}{\sum_k |\alpha_k|}|\le \epsilon / N$ and
    /// $\|\tilde\rho - \rho\|_1\| \le \epsilon$. In other words,
    /// $$
    /// \begin{align}
    /// U\ket{0}^{\lceil\log_2 N\rceil}\ket{0}^{m}=\sum_{j=0}^{N-1}\sqrt{p_j} \ket{j}\ket{\text{garbage}_j}.
    /// \end{align}
    /// $$.
    ///
    /// # Input
    /// ## targetError
    /// The target error $\epsilon$.
    /// ## coefficients
    /// Array of $N$ coefficients specifying the probability of basis states. 
    /// Negative numbers $-\alpha_j$ will be treated as positive $|\alpha_j|$.
    ///
    /// # Output
    /// ## First parameter
    /// A tuple `(x,(y,z))` where `x = y + z` is the total number of qubits allocated,
    /// `y` is the number of qubits for the `BigEndian` register, and `z` is the Number
    /// of garbage qubits.
    /// ## Second parameter
    /// The one-norm $\sum_j |\alpha_j|$ of the coefficient array.
    /// ## Third parameter
    /// The unitary $U$.
    ///
    /// # Example
    /// The following code snippet prepares an purification of the $3$-qubit state 
    /// $\rho=\sum^{4}_{j=0}\frac{|alpha_j|}{\sum_k |\alpha_k|}\ket{j}\bra{j}$, where 
    /// $\vec\alpha=(1.0,2.0,3.0,4.0,5.0)$, and the error is `1e-3`;
    /// ```qsharp
    /// let coefficients = [1.0,2.0,3.0,4.0,5.0];
    /// let targetError = 1e-3;
    /// let ((nTotalQubits, (nIndexQubits, nGarbageQubits)), oneNorm, op) = QuantumROM(targetError, coefficients);
    /// using (indexRegister = Qubit[nIndexQubits]) {
    ///     using (garbageRegister = Qubit[nGarbageQubits]) {
    ///         op(BigEndian(indexRegister), garbageRegister);
    ///     }
    /// }
    /// ```
    ///
    /// # References
    /// - Encoding Electronic Spectra in Quantum Circuits with Linear T Complexity
    ///   Ryan Babbush, Craig Gidney, Dominic W. Berry, Nathan Wiebe, Jarrod McClean, Alexandru Paler, Austin Fowler, Hartmut Neven
    ///   https://arxiv.org/abs/1805.03662
    function QuantumROM(targetError: Double, coefficients: Double[]) : ((Int, (Int, Int)), Double, ((BigEndian, Qubit[]) => Unit : Adjoint, Controlled)) {
        let nBitsPrecision = -Ceiling(Lg(0.5*targetError))+1;
        let (oneNorm, keepCoeff, altIndex) = QuantumROMDiscretization_(nBitsPrecision, coefficients);
        let nCoeffs = Length(coefficients);
        let nBitsIndices = Ceiling(Lg(ToDouble(nCoeffs)));

        let op =  QuantumROMImpl_(nBitsPrecision, nCoeffs, nBitsIndices, keepCoeff, altIndex, _, _);
        let qubitCounts = QuantumROMQubitCount(targetError, nCoeffs);
        return (qubitCounts, oneNorm, op);
    }

    /// # Summary
    /// Returns the total number of qubits that must be allocated
    /// to the operation returned by `QuantumROM`.
    ///
    /// # Input
    /// ## targetError
    /// The target error $\epsilon$.
    /// ## nCoeffs
    /// Number of coefficients specified in `QuantumROM`.
    ///
    /// # Output
    /// ## First parameter
    /// A tuple `(x,(y,z))` where `x = y + z` is the total number of qubits allocated,
    /// `y` is the number of qubits for the `BigEndian` register, and `z` is the Number
    /// of garbage qubits.
    function QuantumROMQubitCount(targetError: Double, nCoeffs: Int) : (Int, (Int, Int))
    {
        let nBitsPrecision = -Ceiling(Lg(0.5*targetError))+1;
        let nBitsIndices = Ceiling(Lg(ToDouble(nCoeffs)));
        let nGarbageQubits = nBitsIndices + 2 * nBitsPrecision + 1;
        let nTotal = nGarbageQubits + nBitsIndices;
        return (nTotal, (nBitsIndices, nGarbageQubits));
    }

    // Implementation step of `QuantumROM`. This splits a single
    // qubit array into the subarrays required by the operation.
    function QuantumROMQubitManager_(targetError: Double, nCoeffs: Int, qubits: Qubit[]) : ((BigEndian, Qubit[]), Qubit[]) {
        let (nTotal, (nIndexRegister, nGarbageQubits)) = QuantumROMQubitCount(targetError, nCoeffs);
        let registers = SplitArray([nIndexRegister, nGarbageQubits], qubits);
        return((BigEndian(registers[0]), registers[1]), registers[2]);
    }

    // Classical processing
    // This discretizes the coefficients such that
    // |coefficient[i] * oneNorm - discretizedCoefficient[i] * discreizedOneNorm| * nCoeffs <= 2^{1-bitsPrecision}.  
    function QuantumROMDiscretization_(bitsPrecision: Int, coefficients: Double[]) : (Double, Int[], Int[]) {
        let oneNorm = PNorm(1.0, coefficients);
        let nCoefficients = Length(coefficients);
        if(bitsPrecision > 31){
            fail $"Bits of precision {bitsPrecision} unsurpported. Max is 31.";
        }
        if(nCoefficients <= 1){
            fail $"Cannot prepare state with less than 2 coefficients.";
        }
        if(oneNorm == 0.0){
            fail $"State must have at least one coefficient > 0";
        }

        let barHeight = 2^bitsPrecision - 1;
        
        mutable altIndex = IntArrayFromRange(0..nCoefficients-1);
        mutable keepCoeff = Map(QuantumROMDiscretizationRoundCoefficients_(_, oneNorm, nCoefficients, barHeight), coefficients);

        // Calculate difference between number of discretized bars vs. maximum
        mutable bars = 0;
        for(idxCoeff in 0..nCoefficients-1){
            set bars = bars + keepCoeff[idxCoeff] - barHeight;
        }
        //Message($"Excess bars {bars}.");
        // Uniformly distribute excess bars acress coefficients.
        for(idx in 0..AbsI(bars)-1){
            if(bars > 0){
                set keepCoeff[idx] = keepCoeff[idx]-1;
            }
            else{
                set keepCoeff[idx] = keepCoeff[idx]+1;
            }
        }

        mutable barSink = new Int[nCoefficients];
        mutable barSource = new Int[nCoefficients];
        mutable nBarSink = 0;
        mutable nBarSource = 0;

        for(idxCoeff in 0..nCoefficients-1) {
            if(keepCoeff[idxCoeff] > barHeight){
                set barSource[nBarSource] = idxCoeff;
                set nBarSource = nBarSource + 1;
            }
            elif(keepCoeff[idxCoeff] < barHeight){
                set barSink[nBarSink] = idxCoeff;
                set nBarSink = nBarSink + 1;
            }
        }

        for(rep in 0..nCoefficients * 10){
            if(nBarSource > 0 && nBarSink > 0){
                let idxSink = barSink[nBarSink-1];
                let idxSource = barSource[nBarSource-1];
                set nBarSink = nBarSink - 1;
                set nBarSource = nBarSource - 1;

                set keepCoeff[idxSource] = keepCoeff[idxSource] - barHeight + keepCoeff[idxSink];
                set altIndex[idxSink] = idxSource;

                if (keepCoeff[idxSource] < barHeight)
                {
                    set barSink[nBarSink] = idxSource;
                    set nBarSink = nBarSink + 1;
                }
                elif(keepCoeff[idxSource] > barHeight)
                {
                    set barSource[nBarSource] = idxSource;
                    set nBarSource = nBarSource + 1;
                }
            }
            elif(nBarSource > 0){
                //Message($"rep: {rep}, nBarSource {nBarSource}.");
                let idxSource = barSource[nBarSource-1];
                set nBarSource = nBarSource - 1;
                set keepCoeff[idxSource] = barHeight;
            }
            else {
                return (oneNorm, keepCoeff, altIndex);
            }
        }
        
        return (oneNorm, keepCoeff, altIndex);
    }
        
    // Used in QuantumROM implementation.
    function QuantumROMDiscretizationRoundCoefficients_(coefficient: Double, oneNorm: Double, nCoefficients: Int, barHeight: Int) : Int {

        return Round((AbsD(coefficient) / oneNorm) * ToDouble(nCoefficients) * ToDouble(barHeight));
    }

    // Used in QuantumROM implementation.
    operation QuantumROMImpl_(nBitsPrecision: Int, nCoeffs: Int, nBitsIndices: Int, keepCoeff: Int[], altIndex: Int[], indexRegister: BigEndian, garbageRegister: Qubit[]) : Unit {
        body (...) {
            let unitaryGenerator = (nCoeffs, QuantumROMWriteBitStringUnitary_(_, keepCoeff, altIndex));

            
            
            let garbageIdx0 = nBitsIndices;
            let garbageIdx1 = garbageIdx0 + nBitsPrecision;
            let garbageIdx2 = garbageIdx1 + nBitsPrecision;
            let garbageIdx3 = garbageIdx2 + 1;

            let altIndexRegister = BigEndian(garbageRegister[0..garbageIdx0-1]);
            let keepCoeffRegister = BigEndian(garbageRegister[garbageIdx0..garbageIdx1 - 1]);
            let uniformKeepCoeffRegister = BigEndian(garbageRegister[garbageIdx1..garbageIdx2 - 1]);
            let flagQubit = garbageRegister[garbageIdx3 - 1];

            // Create uniform superposition over index and alt coeff register.
            PrepareUniformSuperposition(nCoeffs, indexRegister);
            ApplyToEachCA(H, uniformKeepCoeffRegister!);

            // Write bitstrings to altIndex and keepCoeff register.
            MultiplexOperationsFromGenerator(unitaryGenerator, indexRegister, (keepCoeffRegister, altIndexRegister));

            // Perform comparison
            ApplyRippleCarryComparatorBE(uniformKeepCoeffRegister, keepCoeffRegister, flagQubit);

            let indexRegisterSize = Length(indexRegister!);
            
            // Swap in register based on comparison
            for(idx in 0..nBitsIndices-1){
                (Controlled SWAP)([flagQubit], (indexRegister![Length(indexRegister!) - nBitsIndices + idx], altIndexRegister![idx]));
            }
        }
        adjoint auto;
        controlled auto;
        adjoint controlled auto;
    }

    // Used in QuantumROM implementation.
    function QuantumROMWriteBitStringUnitary_(idx: Int, keepCoeff: Int[], altIndex: Int[]) : ((BigEndian, BigEndian) => Unit : Adjoint, Controlled) {
        return QuantumROMWriteBitString_(idx, keepCoeff, altIndex, _, _);
    }

    // Used in QuantumROM implementation.
    operation QuantumROMWriteBitString_(idx: Int, keepCoeff: Int[], altIndex: Int[], keepCoeffRegister: BigEndian, altIndexRegister: BigEndian) : Unit {
        body (...) {
            InPlaceXorBE(keepCoeff[idx], keepCoeffRegister);
            InPlaceXorBE(altIndex[idx], altIndexRegister);
        }
        adjoint auto;
        controlled auto;
        adjoint controlled auto;
    }



}
